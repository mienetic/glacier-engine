//! Strict fixed-width four-request decode cohort.
//!
//! This first production slice is deliberately narrow: AArch64, one
//! homogeneous prepared PairNibble image, packed INT4 rows4/K16 weights with
//! Q8 activations, and equal non-empty prompt lengths. The default head remains
//! materialized; an explicit strict policy reduces finite greedy logits inside
//! native M4 row shards without allocating vocabulary rows. Neither contract ever
//! falls back to four M1 requests.
//! Weight-stationary M4 kernels share immutable model streams while KV,
//! positions, Xoshiro state, output journals, EOS retirement, and completion
//! receipts remain lane-local.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const tensor = core.tensor;
const resource_bank = core.resource_bank;
const forward = @import("forward.zig");
const generate_api = @import("generate.zig");
const int4_matmul = @import("backends/cpu/int4_matmul.zig");
const int4_weights = @import("int4_weights.zig");
const kernels = @import("backends/cpu/kernels.zig");
const kv = @import("kv_cache.zig");
const paged_kv = @import("paged_kv_cache.zig");
const leased_paged_kv = @import("leased_paged_kv_cache.zig");
const paged_attention = @import("paged_attention.zig");
const paged_elastic_token_txn = @import("paged_elastic_token_txn.zig");
const paged_lease_token_txn = @import("paged_lease_token_txn.zig");
const paged_token_txn = @import("paged_token_txn.zig");
const loader = @import("loader.zig");
const prefill_buffers = @import("prefill_buffers.zig");
const sampling = @import("sampling.zig");
const token_txn = @import("token_txn.zig");

pub const abi: u64 = 0x4744_4c34_0000_0004;
pub const width: usize = 4;

/// Process-local strict B4 greedy-head contract. This is deliberately
/// independent of DecodeLane4 v3: enabling the policy changes head ownership
/// and resource accounting, while the default materialized v3 path remains
/// byte-for-byte selectable for retained evidence.
pub const greedy_head_abi: u64 = 0x4742_3448_0000_0002;
pub const projection_wave_abi =
    int4_matmul.prepared_batch_projection_wave_abi;
pub const shared_kv_attention_abi: u64 = 0x4742_3441_0000_0001;
pub const pair_down_wave_abi =
    int4_matmul.pair_nibble_silu_q8_down_wave_abi;
/// Strict P2b execution identity. It binds the all-layer page-bundle layout,
/// serial paged attention, and PagedTokenTxn P2b v1 publication contract.
pub const paged_decode_abi: u64 = 0x4744_5032_0000_0001;
/// P2c-a strict identity: page-map parent receipt plus generation-fenced
/// allocator-backed payload child and PagedElasticTokenTxn v2.
pub const paged_resident_decode_abi: u64 = 0x4744_5032_0000_0002;
/// P2c-b strict identity: exact per-page LeaseTree ownership, whole-wave
/// token/KV/RNG/output publication, and post-publication lane reclamation.
pub const paged_lease_decode_abi: u64 = 0x4744_5032_0000_0004;

pub const KvCacheMode = enum(u8) {
    contiguous,
    paged16_required,
};

/// How a strict paged request is charged. The default preserves P2b's full
/// immutable capacity receipt. The resident-child arm is a separate P2c-a
/// contract whose parent charges page maps and whose generation-fenced child
/// grows by allocator-backed page payload commitments before allocation.
pub const PagedAdmissionMode = enum(u8) {
    flat_capacity,
    resident_child_required,
    lease_tree_required,
};

pub const GreedyHeadMode = enum(u8) {
    materialized,
    streaming_required,
};

/// Lane-local attention arithmetic policy. The shared-KV mode never creates
/// nested pool work: one existing lane job evaluates exact 2..4-query-head
/// tiles around each shared GQA K/V stream.
pub const AttentionMode = enum(u8) {
    serial,
    shared_kv_required,
};

/// Pair/SwiGLU-Q8 to prepared-down worker ownership. The split arm is retained
/// as a byte-exact timing control; the strict wave arm admits every background
/// participant before the first write and then crosses one publication
/// barrier without a second closure cohort or caller join.
pub const PairDownMode = enum(u8) {
    split_control,
    single_epoch_required,
};

pub const LeaseReclaimPolicy = enum(u8) {
    retain_until_teardown,
    terminal_immediate,
};

/// Optional scheduler/rejection evidence ABIs. Both callbacks run only at a
/// cohort-quiescent boundary, outside the ResourceBank mutex, and receive
/// immutable copies. The Bank snapshot is sampled after the cohort-owned tree
/// and lane state; it is not a Bank-wide atomic snapshot when unrelated
/// cohorts are allowed to mutate the same Bank concurrently. Callers that need
/// a causal checkpoint must freeze those cohorts, as the admission runner does.
/// Callbacks may synchronously block to hand execution to another cohort; they
/// must not re-enter the same cohort.
pub const paged_lease_wave_observer_abi: u64 = 0x4744_5059_0000_0001;
pub const paged_lease_admission_observer_abi: u64 = 0x4744_5041_0000_0001;

pub const PagedLeaseTreeStateV1 =
    paged_lease_token_txn.LeaseTreeCommitmentV3;

pub const PagedLeaseWaveEvidenceV1 = struct {
    abi_version: u64 = paged_lease_wave_observer_abi,
    request_epoch: u64,
    transaction_sequence: u64,
    next_sequence: u64,
    published_live_mask: u8,
    terminal_mask: u8,
    remaining_live_mask: u8,
    reclaimed_mask: u8,
    reclaim_policy: LeaseReclaimPolicy,
    proposal_sha256: [32]u8,
    commit_sha256: [32]u8,
    tree: PagedLeaseTreeStateV1,
    bank: resource_bank.SnapshotV3,
};

pub const PagedLeaseWaveObserver = struct {
    abi_version: u64 = paged_lease_wave_observer_abi,
    context: *anyopaque,
    observe: *const fn (
        context: *anyopaque,
        evidence: *const PagedLeaseWaveEvidenceV1,
    ) void,
};

pub const PagedLeaseAdmissionFailureKind = enum(u8) {
    capacity_exceeded,
    lease_nodes_exhausted,
    cache_full,
    allocator_exhausted,
    invalid_transition,
};

pub const PagedLeaseLaneAdmissionStateV1 = struct {
    root: paged_kv.PageMapRootV1,
    allocation: paged_kv.AllocationCommitmentLedger,
    lifecycle: leased_paged_kv.LeaseLifecycle,
};

pub const PagedLeaseAdmissionFailureV1 = struct {
    abi_version: u64 = paged_lease_admission_observer_abi,
    request_epoch: u64,
    transaction_sequence: u64,
    failed_lane: u32,
    active_mask: u8,
    failure: PagedLeaseAdmissionFailureKind,
    tree: PagedLeaseTreeStateV1,
    lanes: [width]PagedLeaseLaneAdmissionStateV1,
    bank: resource_bank.SnapshotV3,
};

pub const PagedLeaseAdmissionObserver = struct {
    abi_version: u64 = paged_lease_admission_observer_abi,
    context: *anyopaque,
    observe: *const fn (
        context: *anyopaque,
        evidence: *const PagedLeaseAdmissionFailureV1,
    ) void,
};

/// Token publication boundary. Legacy publication retains the existing
/// per-lane observer contract. The strict TokenTxn arm instead commits the
/// complete live wave's KV/RNG/output/retirement state through one prepared,
/// infallible batch sink and rejects any simultaneous legacy observer.
pub const PublicationMode = enum(u8) {
    legacy_observer,
    token_txn_required,
    paged_token_txn_required,
    paged_elastic_token_txn_required,
    paged_lease_token_txn_required,
};

pub const TokenTxnPublication = struct {
    request_epoch: u64,
    sink: token_txn.SinkV1,
};

pub const PagedTokenTxnPublication = struct {
    request_epoch: u64,
    sink: paged_token_txn.SinkV1,
};

pub const PagedElasticTokenTxnPublication = struct {
    request_epoch: u64,
    sink: paged_elastic_token_txn.SinkV2,
};

pub const PagedLeaseTokenTxnPublication = struct {
    request_epoch: u64,
    sink: paged_lease_token_txn.SinkV3,
};

fn publicationMode(options: Options) PublicationMode {
    return if (options.paged_lease_token_txn_publication != null)
        .paged_lease_token_txn_required
    else if (options.paged_elastic_token_txn_publication != null)
        .paged_elastic_token_txn_required
    else if (options.paged_token_txn_publication != null)
        .paged_token_txn_required
    else if (options.token_txn_publication != null)
        .token_txn_required
    else
        .legacy_observer;
}

const max_thread_participants: usize = 8;

extern fn glacier_int4_gemm_neon_q8_prequant_f16scale_rows4_k16_m4(
    q_inputs: [*]const i8,
    activation_scales: [*]const f32,
    packed_weights: [*]const u8,
    scales: [*]const f16,
    bias: ?[*]const f32,
    output: [*]f32,
    batch: usize,
    out_features: usize,
    in_features: usize,
    group_size: usize,
    output_stride: usize,
) void;

const NativeGreedyHeadCandidate = extern struct {
    value: f32,
    token_id: usize,
    valid: c_int,
    saw_nan: c_int,
};

comptime {
    if (builtin.cpu.arch == .aarch64 and
        (@sizeOf(NativeGreedyHeadCandidate) != 24 or
            @offsetOf(NativeGreedyHeadCandidate, "value") != 0 or
            @offsetOf(NativeGreedyHeadCandidate, "token_id") != 8 or
            @offsetOf(NativeGreedyHeadCandidate, "valid") != 16 or
            @offsetOf(NativeGreedyHeadCandidate, "saw_nan") != 20))
        @compileError("native M4 argmax result ABI mismatch");
}

extern fn glacier_int4_gemm_neon_q8_prequant_f16scale_rows4_k16_m4_argmax_v2(
    q_inputs: [*]const i8,
    activation_scales: [*]const f32,
    packed_weights: [*]const u8,
    scales: [*]const f16,
    bias: ?[*]const f32,
    out_features: usize,
    in_features: usize,
    group_size: usize,
    row_offset: usize,
    argmax: *[width]NativeGreedyHeadCandidate,
) c_int;

pub const Request = struct {
    prompt: []const u32,
    max_new_tokens: usize,
    eos_token: u32 = std.math.maxInt(u32),
    sampler: sampling.SamplerConfig = .{ .temperature = 0 },
    seed: u64 = 0,
    forced_tokens: []const u32 = &.{},
};

pub const Options = struct {
    /// Total participants including the caller. Zero selects min(4, CPUs).
    /// V4 requires at least two and at most eight participants.
    num_threads: usize = 0,
    /// Required by `generate`: one receipt charges all four logical queue
    /// slots before any request allocation. `deriveResourceClaim` does not
    /// consume this pointer. P2c-a may attach one aggregate allocator child;
    /// per-page LeaseTree refill/reclaim remains outside this contract.
    request_resource_bank: ?*resource_bank.Bank = null,
    resource_telemetry: ?*generate_api.RequestResourceTelemetry = null,
    /// Optional fail-closed post-commit evidence observer shared with M1.
    /// It runs before the retained pool and every cohort/request allocation.
    resource_commit_observer: ?generate_api.ResourceCommitObserver = null,
    /// Contextful per-token event stream shared with M1. DecodeLane4 replaces
    /// the observer's logical index with the publishing lane on every event.
    token_publication_observer: ?generate_api.TokenPublicationObserver = null,
    /// Strict atomic live-wave publication. Its request epoch must be nonzero,
    /// the sink must implement TokenTxn SinkV1, and the legacy per-token
    /// observer must be absent. Prompt KV remains committed before the first
    /// no-KV token transaction; later decode rows stay provisional until the
    /// corresponding transaction commits.
    token_txn_publication: ?TokenTxnPublication = null,
    /// P2b is a separate fail-closed ABI: it never shares TokenTxn v1 sinks
    /// and is valid only with `kv_cache_mode = .paged16_required`.
    paged_token_txn_publication: ?PagedTokenTxnPublication = null,
    /// P2c-a is a separate ABI and requires resident-child admission. The
    /// parent receipt charges page maps; the child charges allocated page
    /// payload commitments and grows before `alignedAlloc`.
    paged_elastic_token_txn_publication: ?PagedElasticTokenTxnPublication = null,
    /// P2c-b exact per-page LeaseTree ownership and whole-wave v3
    /// token/KV/RNG/output publication. This mode never falls back to the
    /// aggregate child or raw paged transaction ABIs.
    paged_lease_token_txn_publication: ?PagedLeaseTokenTxnPublication = null,
    /// Quiescent post-publication/post-reclaim scheduler yield.  The callback
    /// observes the exact Bank state before another decode row can allocate.
    paged_lease_wave_observer: ?PagedLeaseWaveObserver = null,
    /// Exact failed-admission receipt emitted after every provisional row has
    /// been aborted, but before teardown frees reusable page payloads.
    paged_lease_admission_observer: ?PagedLeaseAdmissionObserver = null,
    kv_cache_mode: KvCacheMode = .contiguous,
    paged_admission_mode: PagedAdmissionMode = .flat_capacity,
    lease_reclaim_policy: LeaseReclaimPolicy = .terminal_immediate,
    /// Optional cache envelope shared by all lanes. Zero keeps the exact
    /// reachable prompt+decode capacity. A larger envelope separates reserved
    /// capacity from live rows for honest lazy-residency campaigns.
    kv_capacity_positions: usize = 0,
    /// Strict opt-in B4 head policy. `streaming_required` admits only
    /// unforced, EOS-off, temperature-zero requests and fails before Bank
    /// reservation if any lane would require materialized logits.
    greedy_head_mode: GreedyHeadMode = .materialized,
    /// Strict GQA-only candidate. MHA and any geometry that cannot use the
    /// exact shared-KV tile kernel reject before ResourceBank mutation.
    attention_mode: AttentionMode = .serial,
    /// Strict scheduler candidate. Split remains the default until a retained
    /// same-machine confidence campaign clears its promotion gates.
    pair_down_mode: PairDownMode = .split_control,
    telemetry: ?*Telemetry = null,
};

/// Same-source Zig telemetry, not a stable C struct layout. The embedded ABI
/// values identify semantic evidence domains; consumers that persist or cross
/// a process boundary must use a canonical runner schema and rebuild when this
/// source-level struct changes.
pub const Telemetry = struct {
    abi_version: u64 = abi,
    greedy_head_abi_version: u64 = greedy_head_abi,
    projection_wave_abi_version: u64 = projection_wave_abi,
    shared_kv_attention_abi_version: u64 = shared_kv_attention_abi,
    pair_down_wave_abi_version: u64 = pair_down_wave_abi,
    token_txn_abi_version: u64 = token_txn.abi,
    token_txn_sink_abi_version: u64 = token_txn.sink_abi,
    paged_decode_abi_version: u64 = paged_decode_abi,
    paged_kv_abi_version: u64 = paged_kv.abi,
    paged_kv_page_positions: usize = paged_kv.page_positions,
    paged_token_txn_abi_version: u64 = paged_token_txn.abi,
    paged_token_txn_sink_abi_version: u64 = paged_token_txn.sink_abi,
    paged_elastic_token_txn_abi_version: u64 =
        paged_elastic_token_txn.abi,
    paged_elastic_token_txn_sink_abi_version: u64 =
        paged_elastic_token_txn.sink_abi,
    paged_lease_token_txn_abi_version: u64 = paged_lease_token_txn.abi,
    paged_lease_token_txn_sink_abi_version: u64 =
        paged_lease_token_txn.sink_abi,
    paged_resident_decode_abi_version: u64 = paged_resident_decode_abi,
    paged_lease_decode_abi_version: u64 = paged_lease_decode_abi,
    kv_cache_mode: KvCacheMode = .contiguous,
    paged_admission_mode: PagedAdmissionMode = .flat_capacity,
    lease_reclaim_policy: LeaseReclaimPolicy = .terminal_immediate,
    kv_capacity_positions: usize = 0,
    greedy_head_mode: GreedyHeadMode = .materialized,
    attention_mode: AttentionMode = .serial,
    pair_down_mode: PairDownMode = .split_control,
    publication_mode: PublicationMode = .legacy_observer,
    token_txn_request_epoch: u64 = 0,
    admitted_cohorts: usize = 0,
    cohort_width: usize = width,
    thread_participants: usize = 0,
    frame_payload_bytes: usize = 0,
    /// Successfully completed prompt/decode token graphs.
    token_graphs: usize = 0,
    layer_m4_graphs: usize = 0,
    /// Q, K, V, O, and prepared-down dispatches. LM head has its own count.
    projection_m4_dispatches: usize = 0,
    /// Exact Q/K/V prepared-projection dispatch count.
    qkv_projection_dispatches: usize = 0,
    /// Prepared projections submitted through one shared-activation worker
    /// epoch. A usual all-g8 or all-g16 Q/K/V set is one wave, not three.
    qkv_projection_waves: usize = 0,
    /// Actual worker dispatch/join epochs removed relative to executing each
    /// Q/K/V projection independently. Serial narrow members do not count.
    qkv_projection_joins_elided: usize = 0,
    /// Q/K/V consume one RMSNorm activation. V3 quantizes it once per
    /// distinct g8/g16 group, then reuses the prepared rows across projections.
    qkv_activation_quantizations: usize = 0,
    qkv_quantization_reuses: usize = 0,
    weight_stationary_norm_dispatches: usize = 0,
    /// Layers whose two-or-more live lanes were submitted as independent,
    /// disjoint attention jobs to the retained cohort pool.
    lane_parallel_attention_dispatches: usize = 0,
    /// Total live-lane jobs submitted by parallel attention dispatches.
    /// A one-live-lane tail remains serial and is deliberately excluded.
    lane_parallel_attention_tasks: usize = 0,
    /// Pool enqueue failures. The cohort fails closed and never runs the
    /// rejected or not-yet-enqueued jobs inline as a hidden serial fallback.
    lane_attention_enqueue_rejects: usize = 0,
    /// Lane jobs and exact query-head tiles evaluated through the shared-KV
    /// GQA kernel. These counters remain zero for the serial control.
    shared_kv_attention_lane_dispatches: usize = 0,
    shared_kv_attention_tiles: usize = 0,
    pair_m4_dispatches: usize = 0,
    /// Physical Pair+down worker schedule. Logical Pair/down operation counts
    /// above remain stable across the split control and single-epoch arm.
    pair_down_single_epochs: usize = 0,
    pair_down_split_worker_epochs: usize = 0,
    pair_down_joins_elided: usize = 0,
    pair_down_worker_tasks: usize = 0,
    pair_down_background_enqueues: usize = 0,
    pair_down_enqueue_rejects: usize = 0,
    /// Strict TokenTxn publication receipts. The first transaction publishes
    /// the prompt-derived token without a KV transition; every later live lane
    /// contributes one provisional row committed with the same receipt.
    token_txn_commits: usize = 0,
    token_txn_lane_commits: usize = 0,
    token_txn_first_token_commits: usize = 0,
    token_txn_kv_row_commits: usize = 0,
    token_txn_aborts: usize = 0,
    token_txn_provisional_aborts: usize = 0,
    token_txn_sink_rejects: usize = 0,
    token_txn_last_sequence: u64 = 0,
    paged_kv_capacity_bytes: usize = 0,
    paged_kv_resident_bytes: usize = 0,
    paged_kv_committed_payload_bytes: usize = 0,
    paged_kv_capacity_pages: usize = 0,
    paged_kv_allocated_pages: usize = 0,
    paged_kv_committed_pages: usize = 0,
    paged_kv_reusable_pages: usize = 0,
    paged_kv_logical_capacity_bytes: usize = 0,
    paged_kv_page_map_commitment_bytes: usize = 0,
    paged_kv_payload_ceiling_bytes: usize = 0,
    paged_kv_child_current_bytes: usize = 0,
    paged_kv_child_peak_bytes: usize = 0,
    paged_kv_child_growth_events: usize = 0,
    paged_kv_child_capacity_rejects: usize = 0,
    paged_root_commits: usize = 0,
    paged_lease_binding_storage_bytes: usize = 0,
    paged_lease_required_roots: usize = 0,
    paged_lease_required_nodes: usize = 0,
    paged_lease_terminal_lanes: usize = 0,
    paged_lease_reclaimed_lanes: usize = 0,
    paged_lease_reclaimed_payload_bytes: usize = 0,
    paged_lease_retained_payload_bytes: usize = 0,
    paged_lease_peak_payload_bytes: usize = 0,
    lm_head_m4_dispatches: usize = 0,
    materialized_lm_head_m4_dispatches: usize = 0,
    streaming_greedy_head_m4_dispatches: usize = 0,
    /// Native whole-head jobs submitted across all streaming head graphs.
    streaming_greedy_head_tasks: usize = 0,
    /// Contiguous, rows4-aligned vocabulary shards reduced by those jobs.
    streaming_greedy_head_shards: usize = 0,
    /// Retained for ABI-readable evidence. V2 never materializes row tiles.
    streaming_greedy_head_tiles: usize = 0,
    /// Valid per-lane shard winners returned by the native decision kernel.
    streaming_greedy_head_lane_candidates: usize = 0,
    /// Explicit tile-score payload. V2 reports zero; this is not a claim that
    /// a compiler can never spill scalar or vector registers.
    streaming_greedy_head_tile_scratch_bytes: usize = 0,
    streaming_greedy_head_rejects: usize = 0,
    streaming_greedy_head_enqueue_rejects: usize = 0,
    /// Exact heap payload removed relative to the materialized head policy.
    materialized_logits_reclaimed_bytes: usize = 0,
    active_lane_steps: usize = 0,
    padded_lane_steps: usize = 0,
    fallbacks: usize = 0,
    /// Completion receipts are intentionally hashed on the retained
    /// four-participant pool. Four independent M1 roots hash in parallel too;
    /// a serial B4 postlude would otherwise contaminate join latency.
    state_hash_parallel_dispatches: usize = 0,
    state_hash_tasks: usize = 0,
    state_hash_enqueue_rejects: usize = 0,
    lane_states: [width]generate_api.GenerationStateTelemetry =
        [_]generate_api.GenerationStateTelemetry{.{}} ** width,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    storage: [width][]u32,
    lengths: [width]usize,

    pub fn tokens(self: *const Result, lane: usize) []const u32 {
        std.debug.assert(lane < width);
        return self.storage[lane][0..self.lengths[lane]];
    }

    pub fn deinit(self: *Result) void {
        for (&self.storage) |*journal| {
            self.allocator.free(journal.*);
            journal.* = &.{};
        }
        self.lengths = [_]usize{0} ** width;
    }
};

const Plan = struct {
    frame_spec: prefill_buffers.Spec,
    claim: resource_bank.Claim,
    threads: usize,
    max_context: usize,
    lane_contexts: [width]usize,
    materialized_logits_bytes: usize,
    paged_kv_logical_capacity_bytes: usize,
    paged_kv_page_map_bytes: usize,
    paged_kv_payload_ceiling_bytes: usize,
    paged_kv_bounded_payload_bytes: usize,
    paged_kv_lane_bounded_payload_bytes: [width]usize,
    paged_kv_binding_storage_bytes: usize,
    paged_kv_required_lease_nodes: usize,
};

const PagedKvEnvelope = struct {
    logical_capacity_bytes: usize = 0,
    page_map_bytes: usize = 0,
    payload_ceiling_bytes: usize = 0,
    bounded_payload_bytes: usize = 0,
    lane_bounded_payload_bytes: [width]usize = [_]usize{0} ** width,
    binding_storage_bytes: usize = 0,
    required_lease_nodes: usize = 0,
};

const RopeTable = struct {
    allocator: std.mem.Allocator,
    cos: []f32,
    sin: []f32,
    positions: usize,
    half_dim: usize,

    fn init(
        allocator: std.mem.Allocator,
        positions: usize,
        head_dim: usize,
        theta: f32,
    ) !RopeTable {
        const half_dim = head_dim / 2;
        const count = std.math.mul(usize, positions, half_dim) catch
            return error.OutOfMemory;
        const cos = try allocator.alloc(f32, count);
        errdefer allocator.free(cos);
        const sin = try allocator.alloc(f32, count);
        errdefer allocator.free(sin);
        for (0..positions) |pos| {
            for (0..half_dim) |pair| {
                const exponent = @as(f32, @floatFromInt(2 * pair)) /
                    @as(f32, @floatFromInt(head_dim));
                const frequency = 1.0 / std.math.pow(f32, theta, exponent);
                const angle = @as(f32, @floatFromInt(pos)) * frequency;
                cos[pos * half_dim + pair] = std.math.cos(angle);
                sin[pos * half_dim + pair] = std.math.sin(angle);
            }
        }
        return .{
            .allocator = allocator,
            .cos = cos,
            .sin = sin,
            .positions = positions,
            .half_dim = half_dim,
        };
    }

    fn deinit(self: *RopeTable) void {
        self.allocator.free(self.cos);
        self.allocator.free(self.sin);
    }

    fn apply(
        self: *const RopeTable,
        row: []f32,
        position: usize,
        heads: usize,
        head_dim: usize,
    ) void {
        std.debug.assert(position < self.positions);
        std.debug.assert(head_dim / 2 == self.half_dim);
        const factors = position * self.half_dim;
        for (0..heads) |head| {
            const offset = head * head_dim;
            for (0..self.half_dim) |pair| {
                const low = offset + pair;
                const high = low + self.half_dim;
                const x0 = row[low];
                const x1 = row[high];
                const c = self.cos[factors + pair];
                const s = self.sin[factors + pair];
                row[low] = x0 * c - x1 * s;
                row[high] = x0 * s + x1 * c;
            }
        }
    }
};

fn checkedMul(left: usize, right: usize) generate_api.GenerateError!usize {
    return std.math.mul(usize, left, right) catch
        generate_api.GenerateError.ResourceAdmissionUnavailable;
}

fn checkedAdd(left: usize, right: usize) generate_api.GenerateError!usize {
    return std.math.add(usize, left, right) catch
        generate_api.GenerateError.ResourceAdmissionUnavailable;
}

fn toU64(value: usize) generate_api.GenerateError!u64 {
    return std.math.cast(u64, value) orelse
        generate_api.GenerateError.ResourceAdmissionUnavailable;
}

fn supportedPackedWeight(
    maybe_weight: ?int4_weights.Int4WeightData,
    out_f: usize,
    in_f: usize,
) bool {
    const weight = maybe_weight orelse return false;
    const elements = std.math.mul(usize, out_f, in_f) catch return false;
    if (out_f == 0 or in_f == 0 or out_f % 4 != 0 or in_f % 16 != 0 or
        weight.num_elements != elements or
        weight.packed_layout != .rows4_k16 or
        (weight.group_size != 8 and weight.group_size != 16) or
        weight.expanded_i8.len != 0)
        return false;
    const scale_count = elements / weight.group_size +
        @intFromBool(elements % weight.group_size != 0);
    return weight.packed_bytes.len >= (elements + 1) / 2 and
        weight.scales_f16_rows4.len >= scale_count;
}

fn supportedEmbeddingWeight(
    maybe_weight: ?int4_weights.Int4WeightData,
    rows: usize,
    row_width: usize,
) bool {
    if (!supportedPackedWeight(maybe_weight, rows, row_width)) return false;
    const weight = maybe_weight.?;
    const elements = std.math.mul(usize, rows, row_width) catch return false;
    const scale_count = elements / weight.group_size +
        @intFromBool(elements % weight.group_size != 0);
    // Embedding lookup uses the canonical FP32 group scales to reconstruct a
    // single logical row; the M4 projections consume the rows4 FP16 grid.
    return weight.scales.len >= scale_count;
}

fn supportedPairWeight(
    maybe_weight: ?int4_weights.PairNibbleWeightData,
    out_f: usize,
    in_f: usize,
) bool {
    const weight = maybe_weight orelse return false;
    if (weight.out_f != out_f or weight.in_f != in_f or
        weight.num_elements_per_branch !=
            std.math.mul(usize, out_f, in_f) catch return false)
        return false;
    int4_weights.validatePairNibble(weight) catch return false;
    return true;
}

fn biasSupported(bias: []const f32, out_f: usize) bool {
    return bias.len == 0 or bias.len == out_f;
}

fn activationScaleCount(in_f: usize, group_size: u32) ?usize {
    if (group_size != 8 and group_size != 16) return null;
    return int4_matmul.q8ActivationScaleCount(in_f, group_size);
}

fn validateSampler(config: sampling.SamplerConfig) bool {
    return std.math.isFinite(config.temperature) and config.temperature >= 0 and
        std.math.isFinite(config.top_p) and config.top_p > 0 and
        config.top_p <= 1;
}

fn materializedLogitsBytes(vocab_size: usize) generate_api.GenerateError!usize {
    return checkedAdd(
        try checkedMul(try checkedMul(width, vocab_size), @sizeOf(f32)),
        try checkedMul(2, @sizeOf(usize)),
    );
}

fn streamingGreedyPolicySupported(
    vocab_size: usize,
    requests: [width]Request,
) bool {
    for (requests) |request| {
        // Temperature-zero sampling ignores top-k/top-p and consumes no RNG.
        // EOS is off exactly when no vocabulary token can equal the sentinel.
        if (request.sampler.temperature != 0 or
            request.eos_token < vocab_size or
            request.forced_tokens.len != 0)
            return false;
    }
    return true;
}

fn preflight(
    model: loader.LoadedModel,
    requests: [width]Request,
    options: Options,
) generate_api.GenerateError!Plan {
    if (comptime builtin.cpu.arch != .aarch64)
        return generate_api.GenerateError.DecodeLane4Unavailable;
    if (comptime builtin.single_threaded)
        return generate_api.GenerateError.DecodeLane4Unavailable;
    const paged_mode = options.kv_cache_mode == .paged16_required;
    if (paged_mode) {
        if (options.token_txn_publication != null or
            options.token_publication_observer != null or
            options.attention_mode != .serial)
            return generate_api.GenerateError.TokenTransactionRejected;
        switch (options.paged_admission_mode) {
            .flat_capacity => {
                const publication = options.paged_token_txn_publication orelse
                    return generate_api.GenerateError.TokenTransactionRejected;
                if (options.paged_elastic_token_txn_publication != null or
                    options.paged_lease_token_txn_publication != null or
                    options.paged_lease_wave_observer != null or
                    options.paged_lease_admission_observer != null or
                    publication.request_epoch == 0 or
                    publication.sink.abi_version != paged_token_txn.sink_abi)
                    return generate_api.GenerateError.TokenTransactionRejected;
            },
            .resident_child_required => {
                const publication = options.paged_elastic_token_txn_publication orelse
                    return generate_api.GenerateError.TokenTransactionRejected;
                if (options.paged_token_txn_publication != null or
                    options.paged_lease_token_txn_publication != null or
                    options.paged_lease_wave_observer != null or
                    options.paged_lease_admission_observer != null or
                    options.resource_commit_observer != null or
                    publication.request_epoch == 0 or
                    publication.sink.abi_version !=
                        paged_elastic_token_txn.sink_abi)
                    return generate_api.GenerateError.TokenTransactionRejected;
            },
            .lease_tree_required => {
                const publication = options.paged_lease_token_txn_publication orelse
                    return generate_api.GenerateError.TokenTransactionRejected;
                if (options.paged_token_txn_publication != null or
                    options.paged_elastic_token_txn_publication != null or
                    options.resource_commit_observer != null or
                    publication.request_epoch == 0 or
                    publication.sink.abi_version != paged_lease_token_txn.sink_abi or
                    (options.paged_lease_wave_observer != null and
                        options.paged_lease_wave_observer.?.abi_version !=
                            paged_lease_wave_observer_abi) or
                    (options.paged_lease_admission_observer != null and
                        options.paged_lease_admission_observer.?.abi_version !=
                            paged_lease_admission_observer_abi))
                    return generate_api.GenerateError.TokenTransactionRejected;
            },
        }
    } else if (options.paged_token_txn_publication != null or
        options.paged_elastic_token_txn_publication != null or
        options.paged_lease_token_txn_publication != null or
        options.paged_lease_wave_observer != null or
        options.paged_lease_admission_observer != null or
        options.paged_admission_mode != .flat_capacity)
    {
        return generate_api.GenerateError.TokenTransactionRejected;
    } else if (options.token_txn_publication) |publication| {
        if (publication.request_epoch == 0 or
            publication.sink.abi_version != token_txn.sink_abi or
            options.token_publication_observer != null)
            return generate_api.GenerateError.TokenTransactionRejected;
    } else if (options.token_publication_observer) |observer| {
        if (observer.abi != generate_api.token_publication_observer_abi)
            return generate_api.GenerateError.TokenPublicationObserverRejected;
    }

    const cfg = model.config;
    if (cfg.num_layers == 0 or cfg.num_layers != model.layers.len or
        cfg.dim == 0 or cfg.hidden_dim < 32 or cfg.vocab_size == 0 or
        cfg.num_heads == 0 or cfg.num_kv_heads == 0 or cfg.head_dim == 0 or
        cfg.head_dim % 2 != 0 or cfg.num_heads % cfg.num_kv_heads != 0 or
        !std.math.isFinite(cfg.rms_eps) or cfg.rms_eps < 0 or
        !std.math.isFinite(cfg.rope_theta) or cfg.rope_theta <= 0 or
        cfg.dim != std.math.mul(usize, cfg.num_heads, cfg.head_dim) catch 0 or
        model.final_norm.len != cfg.dim or
        model.prepared_mlp_layout != .pair_nibble)
        return generate_api.GenerateError.DecodeLane4Unavailable;
    if (options.attention_mode == .shared_kv_required and
        cfg.num_heads == cfg.num_kv_heads)
        return generate_api.GenerateError.DecodeLane4Unavailable;

    const kv_dim = std.math.mul(
        usize,
        cfg.num_kv_heads,
        cfg.head_dim,
    ) catch return generate_api.GenerateError.DecodeLane4Unavailable;
    if (!supportedEmbeddingWeight(model.token_embedding_int4, cfg.vocab_size, cfg.dim) or
        !supportedPackedWeight(model.lm_head_int4, cfg.vocab_size, cfg.dim))
        return generate_api.GenerateError.DecodeLane4Unavailable;

    var max_scale_stride: usize = 0;
    var pair_scale_stride: usize = 0;
    for (model.layers) |layer| {
        if (layer.input_norm.len != cfg.dim or
            layer.post_attn_norm.len != cfg.dim or
            !biasSupported(layer.bq, cfg.dim) or
            !biasSupported(layer.bk, kv_dim) or
            !biasSupported(layer.bv, kv_dim) or
            !biasSupported(layer.bo, cfg.dim) or
            !supportedPackedWeight(layer.wq_int4, cfg.dim, cfg.dim) or
            !supportedPackedWeight(layer.wk_int4, kv_dim, cfg.dim) or
            !supportedPackedWeight(layer.wv_int4, kv_dim, cfg.dim) or
            !supportedPackedWeight(layer.wo_int4, cfg.dim, cfg.dim) or
            !supportedPairWeight(
                layer.w_gate_up_pair_int4,
                cfg.hidden_dim,
                cfg.dim,
            ) or
            !supportedPackedWeight(
                layer.w_down_int4,
                cfg.dim,
                cfg.hidden_dim,
            ) or layer.w_gate.len != 0 or layer.w_up.len != 0 or
            layer.w_gate_f16.len != 0 or layer.w_up_f16.len != 0 or
            layer.w_gate_int4 != null or layer.w_up_int4 != null)
            return generate_api.GenerateError.DecodeLane4Unavailable;

        const common = [_]int4_weights.Int4WeightData{
            layer.wq_int4.?,
            layer.wk_int4.?,
            layer.wv_int4.?,
            layer.wo_int4.?,
        };
        for (common) |weight| {
            max_scale_stride = @max(
                max_scale_stride,
                activationScaleCount(cfg.dim, weight.group_size) orelse
                    return generate_api.GenerateError.DecodeLane4Unavailable,
            );
        }
        const pair = layer.w_gate_up_pair_int4.?;
        max_scale_stride = @max(
            max_scale_stride,
            activationScaleCount(cfg.dim, pair.group_size) orelse
                return generate_api.GenerateError.DecodeLane4Unavailable,
        );
        const down = layer.w_down_int4.?;
        pair_scale_stride = @max(
            pair_scale_stride,
            activationScaleCount(cfg.hidden_dim, down.group_size) orelse
                return generate_api.GenerateError.DecodeLane4Unavailable,
        );
    }
    const lm_head = model.lm_head_int4.?;
    max_scale_stride = @max(
        max_scale_stride,
        activationScaleCount(cfg.dim, lm_head.group_size) orelse
            return generate_api.GenerateError.DecodeLane4Unavailable,
    );

    const first_prompt_len = requests[0].prompt.len;
    if (first_prompt_len == 0)
        return generate_api.GenerateError.ShapeMismatch;
    var lane_contexts: [width]usize = undefined;
    var max_context: usize = 0;
    for (requests, 0..) |request, lane| {
        if (request.prompt.len != first_prompt_len or request.max_new_tokens == 0 or
            !validateSampler(request.sampler) or
            (request.forced_tokens.len != 0 and
                request.forced_tokens.len != request.max_new_tokens))
            return generate_api.GenerateError.ShapeMismatch;
        for (request.prompt) |token| if (token >= cfg.vocab_size)
            return generate_api.GenerateError.ShapeMismatch;
        for (request.forced_tokens) |token| if (token >= cfg.vocab_size)
            return generate_api.GenerateError.ShapeMismatch;
        // The final published token is never fed back through the graph, so
        // the exact reachable KV capacity is prompt + max_new - 1. Do not
        // reserve a permanently unreachable row per lane.
        const reachable_context = std.math.add(
            usize,
            request.prompt.len,
            request.max_new_tokens - 1,
        ) catch return generate_api.GenerateError.ContextTooLong;
        if (reachable_context > forward.max_attention_context)
            return generate_api.GenerateError.ContextTooLong;
        const capacity = if (options.kv_capacity_positions == 0)
            reachable_context
        else
            options.kv_capacity_positions;
        if (capacity < reachable_context or
            capacity > forward.max_attention_context)
            return generate_api.GenerateError.ContextTooLong;
        lane_contexts[lane] = capacity;
        max_context = @max(max_context, reachable_context);
    }
    if (options.greedy_head_mode == .streaming_required and
        !streamingGreedyPolicySupported(cfg.vocab_size, requests))
        return generate_api.GenerateError.LogitlessGreedyUnavailable;

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const selected_threads = if (options.num_threads == 0)
        @min(@as(usize, 4), cpu_count)
    else
        options.num_threads;
    if (selected_threads < 2 or selected_threads > 8 or
        selected_threads > cpu_count)
        return generate_api.GenerateError.DecodeLane4Unavailable;

    const tile_rows: usize = if (cfg.hidden_dim >= 64) 64 else 32;
    // Private Pair tiles are task-slot-major. Bound slots by the number of
    // actual hidden-row shards instead of the participant count so small
    // models do not reserve impossible idle-task scratch.
    const pair_task_slots = @min(
        selected_threads,
        cfg.hidden_dim / tile_rows +
            @intFromBool(cfg.hidden_dim % tile_rows != 0),
    );
    const frame_spec: prefill_buffers.Spec = .{
        .kind = .compact_pair,
        .max_batch = width,
        .dim = cfg.dim,
        .kv_dim = kv_dim,
        .hidden = cfg.hidden_dim,
        .max_scale_stride = max_scale_stride,
        .task_slots = pair_task_slots,
        .capsule_rows = width,
        .tile_rows = tile_rows,
        .pair_scale_stride = pair_scale_stride,
    };
    _ = frame_spec.logicalLedger() catch
        return generate_api.GenerateError.DecodeLane4Unavailable;

    const paged_envelope = if (options.kv_cache_mode == .paged16_required)
        try derivePagedKvEnvelope(cfg, lane_contexts, requests)
    else
        PagedKvEnvelope{};

    const claim = try deriveClaim(
        model,
        requests,
        frame_spec,
        lane_contexts,
        max_context,
        options.greedy_head_mode,
        options.kv_cache_mode,
        options.paged_admission_mode,
    );
    const materialized_logits_bytes = try materializedLogitsBytes(cfg.vocab_size);
    return .{
        .frame_spec = frame_spec,
        .claim = claim,
        .threads = selected_threads,
        .max_context = max_context,
        .lane_contexts = lane_contexts,
        .materialized_logits_bytes = materialized_logits_bytes,
        .paged_kv_logical_capacity_bytes = paged_envelope.logical_capacity_bytes,
        .paged_kv_page_map_bytes = paged_envelope.page_map_bytes,
        .paged_kv_payload_ceiling_bytes = paged_envelope.payload_ceiling_bytes,
        .paged_kv_bounded_payload_bytes = paged_envelope.bounded_payload_bytes,
        .paged_kv_lane_bounded_payload_bytes = paged_envelope.lane_bounded_payload_bytes,
        .paged_kv_binding_storage_bytes = paged_envelope.binding_storage_bytes,
        .paged_kv_required_lease_nodes = paged_envelope.required_lease_nodes,
    };
}

fn derivePagedKvEnvelope(
    cfg: loader.ModelConfig,
    lane_contexts: [width]usize,
    requests: [width]Request,
) generate_api.GenerateError!PagedKvEnvelope {
    const kv_dim = try checkedMul(cfg.num_kv_heads, cfg.head_dim);
    var envelope: PagedKvEnvelope = .{};
    envelope.required_lease_nodes = width;
    for (lane_contexts, 0..) |capacity, lane| {
        const ledger = paged_kv.deriveCapacityLedger(
            cfg.num_layers,
            kv_dim,
            capacity,
        ) catch return generate_api.GenerateError.ResourceAdmissionUnavailable;
        envelope.logical_capacity_bytes = try checkedAdd(
            envelope.logical_capacity_bytes,
            ledger.allocation_capacity_bytes,
        );
        envelope.page_map_bytes = try checkedAdd(
            envelope.page_map_bytes,
            ledger.page_map_bytes,
        );
        envelope.payload_ceiling_bytes = try checkedAdd(
            envelope.payload_ceiling_bytes,
            ledger.tensor_capacity_bytes,
        );
        envelope.binding_storage_bytes = try checkedAdd(
            envelope.binding_storage_bytes,
            leased_paged_kv.bindingStorageBytes(
                ledger.page_count_capacity,
            ) catch return generate_api.GenerateError.ResourceAdmissionUnavailable,
        );
        const reachable = std.math.add(
            usize,
            requests[lane].prompt.len,
            requests[lane].max_new_tokens - 1,
        ) catch return generate_api.GenerateError.ResourceAdmissionUnavailable;
        const reachable_pages = reachable / paged_kv.page_positions +
            @intFromBool(reachable % paged_kv.page_positions != 0);
        const reachable_payload = try checkedMul(
            reachable_pages,
            ledger.page_payload_bytes,
        );
        envelope.lane_bounded_payload_bytes[lane] = reachable_payload;
        envelope.bounded_payload_bytes = try checkedAdd(
            envelope.bounded_payload_bytes,
            reachable_payload,
        );
        envelope.required_lease_nodes = try checkedAdd(
            envelope.required_lease_nodes,
            reachable_pages,
        );
    }
    if (try checkedAdd(
        envelope.page_map_bytes,
        envelope.payload_ceiling_bytes,
    ) != envelope.logical_capacity_bytes)
        return generate_api.GenerateError.ResourceAdmissionUnavailable;
    if (envelope.bounded_payload_bytes > envelope.payload_ceiling_bytes or
        envelope.required_lease_nodes < width)
        return generate_api.GenerateError.ResourceAdmissionUnavailable;
    return envelope;
}

fn deriveClaim(
    model: loader.LoadedModel,
    requests: [width]Request,
    frame_spec: prefill_buffers.Spec,
    lane_contexts: [width]usize,
    max_context: usize,
    greedy_head_mode: GreedyHeadMode,
    kv_cache_mode: KvCacheMode,
    paged_admission_mode: PagedAdmissionMode,
) generate_api.GenerateError!resource_bank.Claim {
    const cfg = model.config;
    const kv_dim = try checkedMul(cfg.num_kv_heads, cfg.head_dim);
    var kv_bytes: usize = 0;
    var capsule_bytes: usize = 0;
    var output_bytes: usize = 0;
    var needs_sampling_scratch = false;
    for (requests, 0..) |request, lane| {
        const lane_kv_bytes = switch (kv_cache_mode) {
            .contiguous => blk: {
                const ledger = kv.deriveLogicalLedger(
                    cfg.num_layers,
                    kv_dim,
                    lane_contexts[lane],
                ) catch return generate_api.GenerateError.ResourceAdmissionUnavailable;
                break :blk ledger.allocation_payload_bytes;
            },
            .paged16_required => blk: {
                const ledger = paged_kv.deriveCapacityLedger(
                    cfg.num_layers,
                    kv_dim,
                    lane_contexts[lane],
                ) catch return generate_api.GenerateError.ResourceAdmissionUnavailable;
                break :blk switch (paged_admission_mode) {
                    .flat_capacity => ledger.allocation_capacity_bytes,
                    .resident_child_required, .lease_tree_required => ledger.page_map_bytes,
                };
            },
        };
        kv_bytes = try checkedAdd(kv_bytes, lane_kv_bytes);
        if (paged_admission_mode == .lease_tree_required) {
            const binding_ledger = paged_kv.deriveCapacityLedger(
                cfg.num_layers,
                kv_dim,
                lane_contexts[lane],
            ) catch return generate_api.GenerateError.ResourceAdmissionUnavailable;
            const binding_bytes = leased_paged_kv.bindingStorageBytes(
                binding_ledger.page_count_capacity,
            ) catch return generate_api.GenerateError.ResourceAdmissionUnavailable;
            capsule_bytes = try checkedAdd(
                capsule_bytes,
                binding_bytes,
            );
        }
        output_bytes = try checkedAdd(
            output_bytes,
            try checkedMul(request.max_new_tokens, @sizeOf(u32)),
        );
        needs_sampling_scratch = needs_sampling_scratch or
            (request.forced_tokens.len == 0 and request.sampler.temperature != 0);
    }
    const frame_ledger = frame_spec.logicalLedger() catch
        return generate_api.GenerateError.ResourceAdmissionUnavailable;
    const logits_bytes = switch (greedy_head_mode) {
        .materialized => try materializedLogitsBytes(cfg.vocab_size),
        .streaming_required => 0,
    };
    const partial_bytes = if (needs_sampling_scratch)
        try checkedMul(cfg.vocab_size, @sizeOf(sampling.Candidate))
    else
        0;
    const rope_values = try checkedMul(
        try checkedMul(max_context, cfg.head_dim / 2),
        2,
    );
    const staging_bytes = try checkedMul(rope_values, @sizeOf(f32));
    const claim: resource_bank.Claim = .{
        // Pool internals, worker stacks, and allocator metadata retain the
        // documented logical-request-v1 exclusion used by GenerateOptions.
        .capsule_bytes = try toU64(capsule_bytes),
        .kv_bytes = try toU64(kv_bytes),
        .activation_bytes = try toU64(frame_ledger.tensor_storage_bytes),
        .partial_bytes = try toU64(partial_bytes),
        .logits_bytes = try toU64(logits_bytes),
        .output_journal_bytes = try toU64(output_bytes),
        .staging_bytes = try toU64(staging_bytes),
        .queue_slots = width,
    };
    _ = claim.hostBytes() catch
        return generate_api.GenerateError.ResourceAdmissionUnavailable;
    return claim;
}

/// Allocation-free exact logical claim for the strict cohort that would run.
pub fn deriveResourceClaim(
    model: loader.LoadedModel,
    requests: [width]Request,
    options: Options,
) generate_api.GenerateError!resource_bank.Claim {
    return (try preflight(model, requests, options)).claim;
}

/// Complete caller-facing P2c-a admission contract. `parent_claim` is the
/// immutable Receipt charge, `child_ceiling` is the logical cache envelope,
/// and `bounded_peak_claim` is the exact allocator-commitment maximum for the
/// request's reachable rows. None of these values is an OS RSS measurement.
pub const ResourceAdmissionEnvelope = struct {
    parent_claim: resource_bank.Claim,
    bounded_peak_claim: resource_bank.Claim,
    child_ceiling: resource_bank.Claim,
    logical_kv_capacity_bytes: u64,
    page_map_bytes: u64,
    bounded_peak_payload_bytes: u64,
    binding_storage_bytes: u64,
    lease_tree_ceiling: resource_bank.Claim,
    lane_bounded_payload_bytes: [width]u64,
    required_lease_roots: u32,
    required_lease_nodes: u32,
    paged_admission_mode: PagedAdmissionMode,
};

pub fn deriveResourceAdmissionEnvelope(
    model: loader.LoadedModel,
    requests: [width]Request,
    options: Options,
) generate_api.GenerateError!ResourceAdmissionEnvelope {
    const plan = try preflight(model, requests, options);
    if (options.paged_admission_mode == .flat_capacity) return .{
        .parent_claim = plan.claim,
        .bounded_peak_claim = plan.claim,
        .child_ceiling = .{},
        .logical_kv_capacity_bytes = plan.claim.kv_bytes,
        .page_map_bytes = 0,
        .bounded_peak_payload_bytes = 0,
        .binding_storage_bytes = 0,
        .lease_tree_ceiling = .{},
        .lane_bounded_payload_bytes = [_]u64{0} ** width,
        .required_lease_roots = 0,
        .required_lease_nodes = 0,
        .paged_admission_mode = .flat_capacity,
    };
    if (options.kv_cache_mode != .paged16_required or
        plan.claim.kv_bytes != plan.paged_kv_page_map_bytes)
        return generate_api.GenerateError.ResourceAdmissionUnavailable;

    const bounded_payload = plan.paged_kv_bounded_payload_bytes;
    if (bounded_payload > plan.paged_kv_payload_ceiling_bytes)
        return generate_api.GenerateError.ResourceAdmissionUnavailable;
    var bounded_claim = plan.claim;
    bounded_claim.kv_bytes = std.math.add(
        u64,
        bounded_claim.kv_bytes,
        try toU64(bounded_payload),
    ) catch return generate_api.GenerateError.ResourceAdmissionUnavailable;
    _ = bounded_claim.hostBytes() catch
        return generate_api.GenerateError.ResourceAdmissionUnavailable;
    var lane_bounded_payload_bytes = [_]u64{0} ** width;
    for (plan.paged_kv_lane_bounded_payload_bytes, 0..) |bytes, lane|
        lane_bounded_payload_bytes[lane] = try toU64(bytes);
    const lease_required =
        options.paged_admission_mode == .lease_tree_required;
    return .{
        .parent_claim = plan.claim,
        .bounded_peak_claim = bounded_claim,
        .child_ceiling = if (lease_required) .{} else .{
            .kv_bytes = try toU64(plan.paged_kv_payload_ceiling_bytes),
        },
        .logical_kv_capacity_bytes = try toU64(
            plan.paged_kv_logical_capacity_bytes,
        ),
        .page_map_bytes = try toU64(plan.paged_kv_page_map_bytes),
        .bounded_peak_payload_bytes = try toU64(bounded_payload),
        .binding_storage_bytes = if (lease_required)
            try toU64(plan.paged_kv_binding_storage_bytes)
        else
            0,
        .lease_tree_ceiling = if (lease_required) .{
            .kv_bytes = try toU64(bounded_payload),
        } else .{},
        .lane_bounded_payload_bytes = if (lease_required)
            lane_bounded_payload_bytes
        else
            [_]u64{0} ** width,
        .required_lease_roots = @intFromBool(lease_required),
        .required_lease_nodes = if (lease_required)
            std.math.cast(u32, plan.paged_kv_required_lease_nodes) orelse
                return generate_api.GenerateError.ResourceAdmissionUnavailable
        else
            0,
        .paged_admission_mode = options.paged_admission_mode,
    };
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

const CohortScheduleIdentity = struct {
    decode_lane4_abi: u64 = abi,
    greedy_head_abi_version: u64 = greedy_head_abi,
    projection_wave_abi_version: u64 = projection_wave_abi,
    shared_kv_attention_abi_version: u64 = shared_kv_attention_abi,
    pair_down_wave_abi_version: u64 = pair_down_wave_abi,
    token_txn_abi_version: u64 = token_txn.abi,
    token_txn_sink_abi_version: u64 = token_txn.sink_abi,
    greedy_head_mode: GreedyHeadMode,
    attention_mode: AttentionMode,
    pair_down_mode: PairDownMode = .split_control,
    publication_mode: PublicationMode = .legacy_observer,
};

fn cohortOwnerKeyBound(
    model: loader.LoadedModel,
    requests: [width]Request,
    threads: usize,
    schedule: CohortScheduleIdentity,
) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-decode-lane4-owner-v4\x00");
    hash.update(&model.source_fingerprint);
    hashU64(&hash, schedule.decode_lane4_abi);
    hashU64(&hash, schedule.greedy_head_abi_version);
    hashU64(&hash, schedule.projection_wave_abi_version);
    hashU64(&hash, schedule.shared_kv_attention_abi_version);
    hashU64(&hash, schedule.pair_down_wave_abi_version);
    hashU64(&hash, schedule.token_txn_abi_version);
    hashU64(&hash, schedule.token_txn_sink_abi_version);
    hashU64(&hash, @intFromEnum(schedule.greedy_head_mode));
    hashU64(&hash, @intFromEnum(schedule.attention_mode));
    hashU64(&hash, @intFromEnum(schedule.pair_down_mode));
    hashU64(&hash, @intFromEnum(schedule.publication_mode));
    hashU64(&hash, threads);
    for (requests, 0..) |request, lane| {
        hashU64(&hash, lane);
        hashU64(&hash, request.prompt.len);
        for (request.prompt) |token| hashU64(&hash, token);
        hashU64(&hash, request.max_new_tokens);
        hashU64(&hash, request.eos_token);
        hashU64(&hash, request.seed);
        hashU64(&hash, @as(u32, @bitCast(request.sampler.temperature)));
        hashU64(&hash, request.sampler.top_k);
        hashU64(&hash, @as(u32, @bitCast(request.sampler.top_p)));
        hashU64(&hash, request.forced_tokens.len);
        for (request.forced_tokens) |token| hashU64(&hash, token);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const result = std.mem.readInt(u64, digest[0..8], .little);
    return if (result == 0) 1 else result;
}

fn cohortOwnerKey(
    model: loader.LoadedModel,
    requests: [width]Request,
    threads: usize,
    greedy_head_mode: GreedyHeadMode,
    attention_mode: AttentionMode,
    pair_down_mode: PairDownMode,
    publication_mode: PublicationMode,
) u64 {
    return cohortOwnerKeyBound(model, requests, threads, .{
        .greedy_head_mode = greedy_head_mode,
        .attention_mode = attention_mode,
        .pair_down_mode = pair_down_mode,
        .publication_mode = publication_mode,
    });
}

fn pagedCohortOwnerKey(
    model: loader.LoadedModel,
    requests: [width]Request,
    threads: usize,
    options: Options,
) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-decode-lane4-paged-owner-p2b-v1\x00");
    hash.update(&model.source_fingerprint);
    hashU64(&hash, abi);
    hashU64(&hash, greedy_head_abi);
    hashU64(&hash, projection_wave_abi);
    hashU64(&hash, shared_kv_attention_abi);
    hashU64(&hash, pair_down_wave_abi);
    hashU64(&hash, paged_decode_abi);
    hashU64(&hash, paged_kv.abi);
    hashU64(&hash, paged_kv.page_ref_abi);
    hashU64(&hash, paged_kv.page_map_root_abi);
    hashU64(&hash, paged_kv.row_txn_abi);
    hashU64(&hash, paged_kv.page_positions);
    hashU64(&hash, paged_token_txn.abi);
    hashU64(&hash, paged_token_txn.page_transition_abi);
    hashU64(&hash, paged_token_txn.sink_abi);
    hashU64(&hash, @intFromEnum(options.kv_cache_mode));
    hashU64(&hash, options.kv_capacity_positions);
    hashU64(&hash, @intFromEnum(options.greedy_head_mode));
    hashU64(&hash, @intFromEnum(options.attention_mode));
    hashU64(&hash, @intFromEnum(options.pair_down_mode));
    hashU64(&hash, @intFromEnum(PublicationMode.paged_token_txn_required));
    hashU64(&hash, threads);
    for (requests, 0..) |request, lane| {
        hashU64(&hash, lane);
        hashU64(&hash, request.prompt.len);
        for (request.prompt) |token| hashU64(&hash, token);
        hashU64(&hash, request.max_new_tokens);
        hashU64(&hash, request.eos_token);
        hashU64(&hash, request.seed);
        hashU64(&hash, @as(u32, @bitCast(request.sampler.temperature)));
        hashU64(&hash, request.sampler.top_k);
        hashU64(&hash, @as(u32, @bitCast(request.sampler.top_p)));
        hashU64(&hash, request.forced_tokens.len);
        for (request.forced_tokens) |token| hashU64(&hash, token);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const result = std.mem.readInt(u64, digest[0..8], .little);
    return if (result == 0) 1 else result;
}

fn pagedResidentCohortOwnerKey(
    model: loader.LoadedModel,
    requests: [width]Request,
    threads: usize,
    options: Options,
) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-decode-lane4-paged-owner-p2c-a-v1\x00");
    hash.update(&model.source_fingerprint);
    hashU64(&hash, pagedCohortOwnerKey(model, requests, threads, options));
    hashU64(&hash, paged_resident_decode_abi);
    hashU64(&hash, resource_bank.child_lease_abi);
    hashU64(&hash, paged_kv.row_allocation_plan_abi);
    hashU64(&hash, paged_elastic_token_txn.abi);
    hashU64(&hash, paged_elastic_token_txn.page_transition_abi);
    hashU64(&hash, paged_elastic_token_txn.sink_abi);
    hashU64(&hash, @intFromEnum(options.paged_admission_mode));
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const result = std.mem.readInt(u64, digest[0..8], .little);
    return if (result == 0) 1 else result;
}

fn pagedLeaseCohortOwnerKey(
    model: loader.LoadedModel,
    requests: [width]Request,
    threads: usize,
    options: Options,
) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-decode-lane4-paged-owner-p2c-b-v1\x00");
    hash.update(&model.source_fingerprint);
    hashU64(&hash, pagedCohortOwnerKey(model, requests, threads, options));
    hashU64(&hash, paged_lease_decode_abi);
    hashU64(&hash, resource_bank.lease_tree_abi);
    hashU64(&hash, resource_bank.lease_node_abi);
    hashU64(&hash, leased_paged_kv.abi);
    hashU64(&hash, leased_paged_kv.binding_abi);
    hashU64(&hash, leased_paged_kv.prepared_token_row_abi);
    hashU64(&hash, leased_paged_kv.terminal_seal_v3_abi);
    hashU64(&hash, paged_lease_token_txn.abi);
    hashU64(&hash, paged_lease_token_txn.sink_abi);
    hashU64(&hash, paged_lease_token_txn.resource_commitment_abi);
    hashU64(&hash, @intFromEnum(options.paged_admission_mode));
    hashU64(&hash, @intFromEnum(options.lease_reclaim_policy));
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const result = std.mem.readInt(u64, digest[0..8], .little);
    return if (result == 0) 1 else result;
}

fn pagedLeaseKey(owner_key: u64, domain: []const u8, lane: ?usize) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-decode-lane4-paged-lease-key-v1\x00");
    hash.update(domain);
    hash.update(&.{0});
    hashU64(&hash, owner_key);
    hashU64(&hash, paged_lease_decode_abi);
    if (lane) |value| hashU64(&hash, value);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const result = std.mem.readInt(u64, digest[0..8], .little);
    return if (result == 0) 1 else result;
}

fn pagedResidentChildKey(owner_key: u64, plan: Plan) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-decode-lane4-paged-resident-child-v1\x00");
    hashU64(&hash, owner_key);
    hashU64(&hash, paged_resident_decode_abi);
    hashU64(&hash, plan.paged_kv_logical_capacity_bytes);
    hashU64(&hash, plan.paged_kv_page_map_bytes);
    hashU64(&hash, plan.paged_kv_payload_ceiling_bytes);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const result = std.mem.readInt(u64, digest[0..8], .little);
    return if (result == 0) 1 else result;
}

fn capacityBoundContiguousOwnerKey(base: u64, positions: usize) u64 {
    std.debug.assert(positions != 0);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-decode-lane4-capacity-owner-v1\x00");
    hashU64(&hash, base);
    hashU64(&hash, @intFromEnum(KvCacheMode.contiguous));
    hashU64(&hash, positions);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const result = std.mem.readInt(u64, digest[0..8], .little);
    return if (result == 0) 1 else result;
}

fn fillClaimTelemetry(
    out: *generate_api.RequestResourceTelemetry,
    claim: resource_bank.Claim,
    owner_key: u64,
) void {
    out.owner_key = owner_key;
    out.host_claim_bytes = claim.hostBytes() catch 0;
    out.capsule_bytes = claim.capsule_bytes;
    out.kv_bytes = claim.kv_bytes;
    out.activation_bytes = claim.activation_bytes;
    out.partial_bytes = claim.partial_bytes;
    out.logits_bytes = claim.logits_bytes;
    out.output_journal_bytes = claim.output_journal_bytes;
    out.staging_bytes = claim.staging_bytes;
    out.device_bytes = claim.device_bytes;
    out.io_bytes = claim.io_bytes;
    out.queue_slots = claim.queue_slots;
}

fn recordBankTelemetry(
    destination: ?*generate_api.RequestResourceTelemetry,
    bank: *resource_bank.Bank,
    claim: resource_bank.Claim,
    owner_key: u64,
    receipt: ?resource_bank.Receipt,
) void {
    const out = destination orelse return;
    fillClaimTelemetry(out, claim, owner_key);
    if (receipt) |value| {
        out.bank_epoch = value.bank_epoch;
        out.receipt_slot_index = value.slot_index;
        out.receipt_generation = value.generation;
        out.receipt_integrity = value.integrity;
    }
    const snapshot = bank.snapshotV2() catch {
        out.derive_rejects +|= 1;
        return;
    };
    out.bank_epoch = snapshot.bank_epoch;
    out.host_limit_bytes = snapshot.limits.host_bytes;
    out.peak_host_bytes = snapshot.peak_host_bytes;
    out.reservations = snapshot.successful_reservations;
    out.commits = snapshot.successful_commits;
    out.cancellations = snapshot.cancellations;
    out.releases = snapshot.releases;
    out.capacity_rejects = snapshot.rejected_capacity;
    out.slot_rejects = snapshot.rejected_slots;
    out.active_reservations = snapshot.active_reservations;
    out.committed_receipts = snapshot.committed_receipts;
    out.active_child_leases = snapshot.active_child_leases;
    out.child_opens = snapshot.child_opens;
    out.child_grows = snapshot.child_grows;
    out.child_shrinks = snapshot.child_shrinks;
    out.child_closes = snapshot.child_closes;
    out.child_capacity_rejects = snapshot.rejected_child_capacity;
}

fn recordChildTelemetry(
    destination: ?*generate_api.RequestResourceTelemetry,
    lease: resource_bank.ChildLease,
    logical_kv_capacity_bytes: usize,
) void {
    const out = destination orelse return;
    out.child_lease_abi_version = lease.abi_version;
    out.child_key = lease.child_key;
    out.child_generation = lease.generation;
    out.child_integrity = lease.integrity;
    out.child_ceiling_kv_bytes = lease.ceiling.kv_bytes;
    out.child_current_kv_bytes = lease.claim.kv_bytes;
    out.logical_kv_capacity_bytes = std.math.cast(
        u64,
        logical_kv_capacity_bytes,
    ) orelse 0;
}

fn mapBankError(err: resource_bank.Error) generate_api.GenerateError {
    return switch (err) {
        error.CapacityExceeded => generate_api.GenerateError.ResourceBudgetExceeded,
        else => generate_api.GenerateError.ResourceAdmissionUnavailable,
    };
}

fn releaseReceipt(
    bank: *resource_bank.Bank,
    receipt: resource_bank.Receipt,
    telemetry: ?*generate_api.RequestResourceTelemetry,
) void {
    bank.release(receipt) catch {
        if (telemetry) |out| out.release_failures +|= 1;
    };
    recordBankTelemetry(
        telemetry,
        bank,
        receipt.claim,
        receipt.owner_key,
        receipt,
    );
}

fn closeResidentChildAssumeValid(
    bank: *resource_bank.Bank,
    maybe_lease: *?resource_bank.ChildLease,
    logical_kv_capacity_bytes: usize,
    telemetry: ?*generate_api.RequestResourceTelemetry,
) void {
    const lease = maybe_lease.* orelse return;
    recordChildTelemetry(telemetry, lease, logical_kv_capacity_bytes);
    bank.closeChild(lease) catch {
        if (telemetry) |out| out.release_failures +|= 1;
        @panic("DecodeLane4 resident child failed to close after cache deinit");
    };
    maybe_lease.* = null;
    recordBankTelemetry(
        telemetry,
        bank,
        lease.parent.claim,
        lease.parent.owner_key,
        lease.parent,
    );
}

fn view(
    values: []f32,
    shape: *[2]usize,
    rows: usize,
    cols: usize,
) tensor.Tensor {
    const count = std.math.mul(usize, rows, cols) catch
        @panic("DecodeLane4 tensor view overflow");
    std.debug.assert(count <= values.len);
    shape.* = .{ rows, cols };
    return .{
        .dtype = .f32,
        .shape = shape,
        .data = std.mem.sliceAsBytes(values[0..count]),
        .allocator = std.heap.page_allocator,
    };
}

fn loadEmbeddingRow(
    model: loader.LoadedModel,
    token: u32,
    out: []f32,
) generate_api.GenerateError!void {
    const embedding_weight = model.token_embedding_int4 orelse
        return generate_api.GenerateError.DecodeLane4Unavailable;
    int4_matmul.dequantizeRow(embedding_weight, token, model.config.dim, out) catch
        return generate_api.GenerateError.ForwardFailed;
}

fn projectBatch(
    pool: *std.Thread.Pool,
    input: tensor.Tensor,
    weight: int4_weights.Int4WeightData,
    bias: []const f32,
    output: tensor.Tensor,
    out_f: usize,
    in_f: usize,
    buffers: *prefill_buffers.Buffers,
    tasks: usize,
) generate_api.GenerateError!void {
    int4_matmul.linearInt4WeightBatchQ8Parallel(
        pool,
        input,
        weight,
        bias,
        output,
        out_f,
        in_f,
        buffers.q_scratch,
        buffers.scale_scratch,
        tasks,
    ) catch return generate_api.GenerateError.ForwardFailed;
}

const SharedActivationProjection = struct {
    weight: int4_weights.Int4WeightData,
    bias: []const f32,
    output: tensor.Tensor,
    out_f: usize,
};

const SharedActivationExecution = struct {
    quantizations: usize = 0,
    worker_joins_elided: usize = 0,
};

/// Quantize one shared activation once for every distinct weight-group ABI,
/// then consume those immutable Q8 rows through all matching projections.
/// Q/K/V commonly share one group and therefore remove two full M4-row
/// quantization passes without changing any projection arithmetic.
fn projectSharedActivation(
    pool: *std.Thread.Pool,
    input: tensor.Tensor,
    in_f: usize,
    projections: []const SharedActivationProjection,
    buffers: *prefill_buffers.Buffers,
    tasks: usize,
) generate_api.GenerateError!SharedActivationExecution {
    var execution: SharedActivationExecution = .{};
    for ([_]u32{ 8, 16 }) |group_size| {
        var wave_storage: [3]int4_matmul.PreparedBatchProjection = undefined;
        var wave_len: usize = 0;
        var independent_worker_epochs: usize = 0;
        var max_out_f: usize = 0;
        for (projections) |projection| {
            if (projection.weight.group_size != group_size) continue;
            if (wave_len >= wave_storage.len)
                return generate_api.GenerateError.ForwardFailed;
            wave_storage[wave_len] = .{
                .weights = projection.weight,
                .bias = projection.bias,
                .out = projection.output,
                .out_f = projection.out_f,
            };
            wave_len += 1;
            max_out_f = @max(max_out_f, projection.out_f);
            independent_worker_epochs += @intFromBool(
                int4_matmul.preparedBatchProjectionUsesWorkerEpoch(
                    projection.out_f,
                    tasks,
                ),
            );
        }
        if (wave_len == 0) continue;
        int4_matmul.quantizeQ8ActivationBatch(
            input.asF32Unsafe(),
            width,
            in_f,
            group_size,
            buffers.q_scratch,
            buffers.scale_scratch,
        ) catch return generate_api.GenerateError.ForwardFailed;
        execution.quantizations += 1;
        int4_matmul.linearInt4WeightQ8PreparedBatchProjectionWave(
            pool,
            buffers.q_scratch,
            buffers.scale_scratch,
            wave_storage[0..wave_len],
            in_f,
            tasks,
        ) catch return generate_api.GenerateError.ForwardFailed;
        const wave_worker_epochs: usize = @intFromBool(
            int4_matmul.preparedBatchProjectionUsesWorkerEpoch(
                max_out_f,
                tasks,
            ),
        );
        if (wave_worker_epochs > independent_worker_epochs)
            return generate_api.GenerateError.ForwardFailed;
        execution.worker_joins_elided +=
            independent_worker_epochs - wave_worker_epochs;
    }
    if (execution.quantizations == 0 or
        execution.quantizations > projections.len)
        return generate_api.GenerateError.ForwardFailed;
    return execution;
}

fn addRows(dst: []f32, left: []const f32, right: []const f32) void {
    std.debug.assert(dst.len == left.len and left.len == right.len);
    for (dst, left, right) |*result, a, b| result.* = a + b;
}

fn publishToken(
    maybe_observer: ?generate_api.TokenPublicationObserver,
    lane: usize,
    step_index: usize,
    token_id: u32,
    terminal: bool,
) generate_api.GenerateError!void {
    var observer = maybe_observer orelse return;
    observer.logical_request_index = std.math.cast(u32, lane) orelse
        return generate_api.GenerateError.TokenPublicationObserverRejected;
    try generate_api.runTokenPublicationObserver(
        observer,
        step_index,
        token_id,
        terminal,
    );
}

const RuntimeKvMark = union(enum) {
    contiguous: kv.RowTxnMark,
    paged16_required: paged_kv.RowTxnMark,
    leased_paged16: leased_paged_kv.LeasedRowTxnV1,
};

/// Decode owns one tagged cache per lane.  The tag is fixed by preflight for
/// the entire cohort; no path allocates both representations or linearizes a
/// paged prefix into a hidden contiguous mirror.
const RuntimeKvCache = union(KvCacheMode) {
    contiguous: kv.KVCache,
    paged16_required: paged_kv.PagedKVCache,

    fn init(
        allocator: std.mem.Allocator,
        mode: KvCacheMode,
        num_layers: usize,
        dim: usize,
        max_seq: usize,
    ) !RuntimeKvCache {
        return switch (mode) {
            .contiguous => .{ .contiguous = try kv.KVCache.init(
                allocator,
                num_layers,
                dim,
                max_seq,
            ) },
            .paged16_required => .{
                .paged16_required = try paged_kv.PagedKVCache.init(
                    allocator,
                    num_layers,
                    dim,
                    max_seq,
                ),
            },
        };
    }

    fn deinit(self: *RuntimeKvCache) void {
        switch (self.*) {
            .contiguous => |*cache| cache.deinit(),
            .paged16_required => |*cache| cache.deinit(),
        }
    }

    fn len(self: *const RuntimeKvCache) usize {
        return switch (self.*) {
            .contiguous => |cache| cache.len,
            .paged16_required => |cache| cache.len,
        };
    }

    fn maxSeq(self: *const RuntimeKvCache) usize {
        return switch (self.*) {
            .contiguous => |cache| cache.max_seq,
            .paged16_required => |cache| cache.max_seq,
        };
    }

    fn beginRow(self: *RuntimeKvCache) !RuntimeKvMark {
        return switch (self.*) {
            .contiguous => |*cache| .{
                .contiguous = try cache.beginRows(1),
            },
            .paged16_required => |*cache| .{
                .paged16_required = try cache.beginRow(),
            },
        };
    }

    fn abortRow(self: *RuntimeKvCache, mark: RuntimeKvMark) !void {
        switch (self.*) {
            .contiguous => |*cache| switch (mark) {
                .contiguous => |value| try cache.abortRows(value),
                else => return error.InvalidTransaction,
            },
            .paged16_required => |*cache| switch (mark) {
                .paged16_required => |value| try cache.abortRow(value),
                else => return error.InvalidTransaction,
            },
        }
    }

    fn appendRow(
        self: *RuntimeKvCache,
        maybe_mark: ?RuntimeKvMark,
        layer: usize,
        k_row: []const f32,
        v_row: []const f32,
    ) !usize {
        return switch (self.*) {
            .contiguous => |*cache| if (maybe_mark) |mark| switch (mark) {
                .contiguous => |value| try cache.appendRowTxn(
                    value,
                    layer,
                    k_row,
                    v_row,
                ),
                else => error.InvalidTransaction,
            } else try cache.appendRow(layer, k_row, v_row),
            .paged16_required => |*cache| if (maybe_mark) |mark| switch (mark) {
                .paged16_required => |value| try cache.appendRowTxn(
                    value,
                    layer,
                    k_row,
                    v_row,
                ),
                else => error.InvalidTransaction,
            } else error.InvalidTransaction,
        };
    }

    fn commitPromptRow(
        self: *RuntimeKvCache,
        mark: RuntimeKvMark,
    ) !void {
        switch (self.*) {
            .contiguous => |*cache| switch (mark) {
                .contiguous => |value| try cache.commitRowsTxn(value),
                else => return error.InvalidTransaction,
            },
            .paged16_required => |*cache| switch (mark) {
                .paged16_required => |value| try cache.commitRowTxn(value),
                else => return error.InvalidTransaction,
            },
        }
    }

    fn commitLegacyGraph(self: *RuntimeKvCache) !void {
        switch (self.*) {
            .contiguous => |*cache| cache.commit(),
            .paged16_required => return error.InvalidTransaction,
        }
    }

    fn contiguousPtr(self: *RuntimeKvCache) ?*kv.KVCache {
        return switch (self.*) {
            .contiguous => |*cache| cache,
            else => null,
        };
    }

    fn pagedPtr(self: *RuntimeKvCache) ?*paged_kv.PagedKVCache {
        return switch (self.*) {
            .paged16_required => |*cache| cache,
            else => null,
        };
    }
};

const StagedToken = struct {
    token_id: u32,
    rng_after: token_txn.RngState,
    sampling_calls_after: usize,
    terminal: bool,
};

fn stageToken(
    model: loader.LoadedModel,
    request: Request,
    lane: usize,
    output_before: usize,
    greedy_head_mode: GreedyHeadMode,
    logits: ?tensor.Tensor,
    streamed_tokens: *const [width]u32,
    prng: std.Random.DefaultPrng,
    sampling_calls_before: usize,
    sample_scratch: []sampling.Candidate,
) generate_api.GenerateError!StagedToken {
    var staged_prng = prng;
    var sampling_calls_after = sampling_calls_before;
    const token = switch (greedy_head_mode) {
        .streaming_required => blk: {
            sampling_calls_after = std.math.add(
                usize,
                sampling_calls_after,
                1,
            ) catch return generate_api.GenerateError.ForwardFailed;
            break :blk streamed_tokens[lane];
        },
        .materialized => if (request.forced_tokens.len != 0)
            request.forced_tokens[output_before]
        else blk: {
            sampling_calls_after = std.math.add(
                usize,
                sampling_calls_after,
                1,
            ) catch return generate_api.GenerateError.ForwardFailed;
            const token_index = sampling.sample(
                logits.?.asF32Unsafe()[lane * model.config.vocab_size ..][0..model.config.vocab_size],
                request.sampler,
                staged_prng.random(),
                sample_scratch,
            );
            break :blk std.math.cast(u32, token_index) orelse
                return generate_api.GenerateError.ForwardFailed;
        },
    };
    return .{
        .token_id = token,
        .rng_after = staged_prng.s,
        .sampling_calls_after = sampling_calls_after,
        .terminal = token == request.eos_token or
            output_before + 1 == request.max_new_tokens,
    };
}

fn stagedTerminalReason(
    request: Request,
    staged: StagedToken,
) ?leased_paged_kv.TerminalReason {
    if (!staged.terminal) return null;
    return if (staged.token_id == request.eos_token)
        .eos
    else
        .max_tokens;
}

fn abortKvMarks(
    caches: *[width]RuntimeKvCache,
    marks: *[width]?RuntimeKvMark,
) bool {
    var clean = true;
    for (marks, 0..) |*maybe_mark, lane| {
        if (maybe_mark.*) |mark| {
            caches[lane].abortRow(mark) catch {
                clean = false;
            };
            maybe_mark.* = null;
        }
    }
    return clean;
}

fn recordTokenTxnProvisionalAbort(telemetry: ?*Telemetry) void {
    const out = telemetry orelse return;
    out.token_txn_aborts +|= 1;
    out.token_txn_provisional_aborts +|= 1;
}

fn beginKvMarks(
    caches: *[width]RuntimeKvCache,
    active: [width]bool,
    telemetry: ?*Telemetry,
) generate_api.GenerateError![width]?RuntimeKvMark {
    var marks = [_]?RuntimeKvMark{null} ** width;
    for (active, 0..) |is_active, lane| {
        if (!is_active) continue;
        marks[lane] = caches[lane].beginRow() catch |err| {
            recordTokenTxnProvisionalAbort(telemetry);
            if (!abortKvMarks(caches, &marks))
                return generate_api.GenerateError.TokenTransactionRejected;
            return switch (err) {
                error.CacheFull => generate_api.GenerateError.CacheFull,
                error.OutOfMemory => generate_api.GenerateError.OutOfMemory,
                else => generate_api.GenerateError.TokenTransactionRejected,
            };
        };
    }
    return marks;
}

fn beginResidentKvMarks(
    caches: *[width]RuntimeKvCache,
    active: [width]bool,
    session: *paged_elastic_token_txn.Session,
    resident_child: *?resource_bank.ChildLease,
    resource_telemetry: ?*generate_api.RequestResourceTelemetry,
    telemetry: ?*Telemetry,
) generate_api.GenerateError![width]?RuntimeKvMark {
    var plans = [_]?paged_kv.RowAllocationPlanV1{null} ** width;
    var current_payload_bytes: usize = 0;
    var growth_bytes: usize = 0;
    for (caches, 0..) |*runtime_cache, lane| {
        const cache = runtime_cache.pagedPtr() orelse
            return generate_api.GenerateError.TokenTransactionRejected;
        const ledger = cache.allocationCommitmentLedger() catch
            return generate_api.GenerateError.TokenTransactionRejected;
        current_payload_bytes = std.math.add(
            usize,
            current_payload_bytes,
            ledger.resident_tensor_payload_bytes,
        ) catch return generate_api.GenerateError.ResourceAdmissionUnavailable;
        if (!active[lane]) continue;
        const plan = cache.planNextRowAllocation() catch |err| switch (err) {
            error.CacheFull => return generate_api.GenerateError.CacheFull,
            else => return generate_api.GenerateError.TokenTransactionRejected,
        };
        plans[lane] = plan;
        growth_bytes = std.math.add(
            usize,
            growth_bytes,
            plan.allocation_bytes,
        ) catch return generate_api.GenerateError.ResourceAdmissionUnavailable;
    }
    const current_u64 = std.math.cast(u64, current_payload_bytes) orelse
        return generate_api.GenerateError.ResourceAdmissionUnavailable;
    const mirror = resident_child.* orelse
        return generate_api.GenerateError.ResourceAdmissionUnavailable;
    if (!std.meta.eql(mirror, session.child_lease) or
        mirror.claim.kv_bytes != current_u64)
        return generate_api.GenerateError.TokenTransactionRejected;

    if (growth_bytes != 0) {
        const target = std.math.add(
            usize,
            current_payload_bytes,
            growth_bytes,
        ) catch return generate_api.GenerateError.ResourceAdmissionUnavailable;
        const target_u64 = std.math.cast(u64, target) orelse
            return generate_api.GenerateError.ResourceAdmissionUnavailable;
        const grown = session.growResidentPayload(
            session.next_sequence,
            target_u64,
        ) catch |err| {
            if (telemetry) |out| {
                out.paged_kv_child_capacity_rejects +|=
                    @intFromBool(err == error.ResourceCapacityExceeded);
            }
            recordBankTelemetry(
                resource_telemetry,
                session.bank,
                session.parent_receipt.claim,
                session.parent_receipt.owner_key,
                session.parent_receipt,
            );
            recordChildTelemetry(
                resource_telemetry,
                mirror,
                std.math.cast(usize, session.logical_kv_capacity) orelse 0,
            );
            return if (err == error.ResourceCapacityExceeded)
                generate_api.GenerateError.ResourceBudgetExceeded
            else
                generate_api.GenerateError.TokenTransactionRejected;
        };
        resident_child.* = grown;
        recordChildTelemetry(
            resource_telemetry,
            grown,
            std.math.cast(usize, session.logical_kv_capacity) orelse 0,
        );
        recordBankTelemetry(
            resource_telemetry,
            session.bank,
            session.parent_receipt.claim,
            session.parent_receipt.owner_key,
            session.parent_receipt,
        );
        if (telemetry) |out| {
            out.paged_kv_child_current_bytes = target;
            out.paged_kv_child_peak_bytes = @max(
                out.paged_kv_child_peak_bytes,
                target,
            );
            out.paged_kv_child_growth_events +|= 1;
        }
    }

    var marks = [_]?RuntimeKvMark{null} ** width;
    for (active, 0..) |is_active, lane| {
        if (!is_active) continue;
        const cache = caches[lane].pagedPtr() orelse unreachable;
        const mark = cache.beginRowPlanned(plans[lane].?) catch |err| {
            recordTokenTxnProvisionalAbort(telemetry);
            if (!abortKvMarks(caches, &marks))
                return generate_api.GenerateError.TokenTransactionRejected;
            return switch (err) {
                error.CacheFull => generate_api.GenerateError.CacheFull,
                error.OutOfMemory => generate_api.GenerateError.OutOfMemory,
                else => generate_api.GenerateError.TokenTransactionRejected,
            };
        };
        marks[lane] = .{ .paged16_required = mark };
    }
    return marks;
}

fn abortLeasedKvMarks(
    coordinators: *[width]leased_paged_kv.LeasedPagedKVCache,
    marks: *[width]?RuntimeKvMark,
) bool {
    var clean = true;
    for (marks, 0..) |*maybe_mark, lane| {
        const runtime_mark = maybe_mark.* orelse continue;
        switch (runtime_mark) {
            .leased_paged16 => |txn| coordinators[lane].abortRowTxn(txn) catch {
                clean = false;
            },
            else => clean = false,
        }
        maybe_mark.* = null;
    }
    return clean;
}

fn activeLaneMask(active: [width]bool) u8 {
    var mask: u8 = 0;
    for (active, 0..) |is_active, lane| if (is_active) {
        mask |= @as(u8, 1) << @intCast(lane);
    };
    return mask;
}

fn pagedLeaseTreeState(tree: resource_bank.LeaseTreeV1) PagedLeaseTreeStateV1 {
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

fn admissionFailureKind(err: anyerror) PagedLeaseAdmissionFailureKind {
    return switch (err) {
        error.CapacityExceeded => .capacity_exceeded,
        error.LeaseNodesExhausted => .lease_nodes_exhausted,
        error.CacheFull => .cache_full,
        error.OutOfMemory => .allocator_exhausted,
        else => .invalid_transition,
    };
}

fn observePagedLeaseAdmissionFailure(
    observer: ?PagedLeaseAdmissionObserver,
    bank: *resource_bank.Bank,
    coordinators: *[width]leased_paged_kv.LeasedPagedKVCache,
    active: [width]bool,
    request_epoch: u64,
    failed_lane: usize,
    err: anyerror,
) generate_api.GenerateError!void {
    const selected = observer orelse return;
    if (failed_lane >= width or request_epoch == 0)
        return generate_api.GenerateError.TokenTransactionRejected;
    var first_active: ?usize = null;
    for (active, 0..) |is_active, lane| if (is_active) {
        first_active = lane;
        break;
    };
    const witness_lane = first_active orelse
        return generate_api.GenerateError.TokenTransactionRejected;
    const tree = coordinators[witness_lane].treeToken() catch
        return generate_api.GenerateError.TokenTransactionRejected;
    const sequence = coordinators[witness_lane].publicationSequence() catch
        return generate_api.GenerateError.TokenTransactionRejected;
    var lanes: [width]PagedLeaseLaneAdmissionStateV1 = undefined;
    for (coordinators, 0..) |*coordinator, lane| {
        lanes[lane] = .{
            .root = coordinator.rootToken() catch
                return generate_api.GenerateError.TokenTransactionRejected,
            .allocation = coordinator.allocationCommitmentLedger() catch
                return generate_api.GenerateError.TokenTransactionRejected,
            .lifecycle = coordinator.lifecycle() catch
                return generate_api.GenerateError.TokenTransactionRejected,
        };
    }
    const evidence: PagedLeaseAdmissionFailureV1 = .{
        .request_epoch = request_epoch,
        .transaction_sequence = sequence,
        .failed_lane = @intCast(failed_lane),
        .active_mask = activeLaneMask(active),
        .failure = admissionFailureKind(err),
        .tree = pagedLeaseTreeState(tree),
        .lanes = lanes,
        .bank = bank.snapshotV3() catch
            return generate_api.GenerateError.TokenTransactionRejected,
    };
    selected.observe(selected.context, &evidence);
}

/// LeaseTree planning and begin are deliberately sequential. Each newly
/// reserved page mutates the one shared tree token, so pre-planning sibling
/// lanes would manufacture stale structural generations.
fn beginLeasedKvMarks(
    bank: *resource_bank.Bank,
    coordinators: *[width]leased_paged_kv.LeasedPagedKVCache,
    active: [width]bool,
    request_epoch: u64,
    admission_observer: ?PagedLeaseAdmissionObserver,
    telemetry: ?*Telemetry,
) generate_api.GenerateError![width]?RuntimeKvMark {
    var marks = [_]?RuntimeKvMark{null} ** width;
    for (active, 0..) |is_active, lane| {
        if (!is_active) continue;
        const plan = coordinators[lane].planNextRow() catch |err| {
            recordTokenTxnProvisionalAbort(telemetry);
            if (!abortLeasedKvMarks(coordinators, &marks))
                return generate_api.GenerateError.TokenTransactionRejected;
            try observePagedLeaseAdmissionFailure(
                admission_observer,
                bank,
                coordinators,
                active,
                request_epoch,
                lane,
                err,
            );
            return switch (err) {
                error.CapacityExceeded => generate_api.GenerateError.ResourceBudgetExceeded,
                error.LeaseNodesExhausted => generate_api.GenerateError.ResourceAdmissionUnavailable,
                error.CacheFull => generate_api.GenerateError.CacheFull,
                error.OutOfMemory => generate_api.GenerateError.OutOfMemory,
                else => generate_api.GenerateError.TokenTransactionRejected,
            };
        };
        const txn = coordinators[lane].beginRowPlanned(plan) catch |err| {
            recordTokenTxnProvisionalAbort(telemetry);
            if (!abortLeasedKvMarks(coordinators, &marks))
                return generate_api.GenerateError.TokenTransactionRejected;
            try observePagedLeaseAdmissionFailure(
                admission_observer,
                bank,
                coordinators,
                active,
                request_epoch,
                lane,
                err,
            );
            return switch (err) {
                error.CapacityExceeded => generate_api.GenerateError.ResourceBudgetExceeded,
                error.LeaseNodesExhausted => generate_api.GenerateError.ResourceAdmissionUnavailable,
                error.CacheFull => generate_api.GenerateError.CacheFull,
                error.OutOfMemory => generate_api.GenerateError.OutOfMemory,
                else => generate_api.GenerateError.TokenTransactionRejected,
            };
        };
        marks[lane] = .{ .leased_paged16 = txn };
    }
    return marks;
}

fn commitLeasedPromptMarks(
    coordinators: *[width]leased_paged_kv.LeasedPagedKVCache,
    marks: *[width]?RuntimeKvMark,
) generate_api.GenerateError!void {
    var prepared: [width]leased_paged_kv.PreparedTokenRowV1 = undefined;
    for (0..width) |lane| {
        const runtime_mark = marks[lane] orelse {
            _ = abortLeasedKvMarks(coordinators, marks);
            return generate_api.GenerateError.TokenTransactionRejected;
        };
        const txn = switch (runtime_mark) {
            .leased_paged16 => |value| value,
            else => {
                _ = abortLeasedKvMarks(coordinators, marks);
                return generate_api.GenerateError.TokenTransactionRejected;
            },
        };
        prepared[lane] = coordinators[lane].prepareTokenRow(
            txn,
            false,
        ) catch {
            _ = abortLeasedKvMarks(coordinators, marks);
            return generate_api.GenerateError.TokenTransactionRejected;
        };
    }
    for (0..width) |lane|
        coordinators[lane].commitPreparedTokenRowAssumeValid(prepared[lane]);
    marks.* = [_]?RuntimeKvMark{null} ** width;
}

fn commitPagedPromptMarks(
    caches: *[width]RuntimeKvCache,
    marks: *[width]?RuntimeKvMark,
) generate_api.GenerateError!void {
    var prepared: [width]paged_kv.PreparedRowCommit = undefined;
    for (0..width) |lane| {
        const cache = caches[lane].pagedPtr() orelse {
            _ = abortKvMarks(caches, marks);
            return generate_api.GenerateError.TokenTransactionRejected;
        };
        const runtime_mark = marks[lane] orelse {
            _ = abortKvMarks(caches, marks);
            return generate_api.GenerateError.TokenTransactionRejected;
        };
        const mark = switch (runtime_mark) {
            .paged16_required => |value| value,
            else => {
                _ = abortKvMarks(caches, marks);
                return generate_api.GenerateError.TokenTransactionRejected;
            },
        };
        prepared[lane] = cache.prepareCommit(mark) catch {
            _ = abortKvMarks(caches, marks);
            return generate_api.GenerateError.TokenTransactionRejected;
        };
    }
    for (0..width) |lane|
        caches[lane].pagedPtr().?.commitPreparedAssumeValid(prepared[lane]);
    marks.* = [_]?RuntimeKvMark{null} ** width;
}

fn recordPagedKvTelemetry(
    caches: *const [width]RuntimeKvCache,
    telemetry: ?*Telemetry,
) generate_api.GenerateError!void {
    const out = telemetry orelse return;
    for (caches) |*runtime_cache| {
        const cache = switch (runtime_cache.*) {
            .paged16_required => |*value| value,
            else => return generate_api.GenerateError.ForwardFailed,
        };
        const capacity = cache.capacityLedger();
        const resident = cache.residentLedger() catch
            return generate_api.GenerateError.TokenTransactionRejected;
        out.paged_kv_capacity_bytes = std.math.add(
            usize,
            out.paged_kv_capacity_bytes,
            capacity.allocation_capacity_bytes,
        ) catch return generate_api.GenerateError.ForwardFailed;
        out.paged_kv_resident_bytes = std.math.add(
            usize,
            out.paged_kv_resident_bytes,
            resident.resident_allocation_bytes,
        ) catch return generate_api.GenerateError.ForwardFailed;
        out.paged_kv_committed_payload_bytes = std.math.add(
            usize,
            out.paged_kv_committed_payload_bytes,
            resident.committed_tensor_payload_bytes,
        ) catch return generate_api.GenerateError.ForwardFailed;
        out.paged_kv_capacity_pages +|= capacity.page_count_capacity;
        out.paged_kv_allocated_pages +|= resident.allocated_pages;
        out.paged_kv_committed_pages +|= resident.committed_pages;
        out.paged_kv_reusable_pages +|= resident.reusable_pages;
    }
}

fn commitTokenWave(
    session: *token_txn.Session,
    publication: TokenTxnPublication,
    requests: [width]Request,
    caches: *[width]RuntimeKvCache,
    marks: *[width]?RuntimeKvMark,
    staged: *const [width]?StagedToken,
    prngs: *[width]std.Random.DefaultPrng,
    sampling_calls: *[width]usize,
    result: *Result,
    active: *[width]bool,
    telemetry: ?*Telemetry,
) generate_api.GenerateError!void {
    var lane_stages: [width]token_txn.LaneStage = undefined;
    var live_count: usize = 0;
    for (active, 0..) |is_active, lane| {
        if (!is_active) {
            if (marks[lane] != null or staged[lane] != null) {
                _ = abortKvMarks(caches, marks);
                recordTokenTxnProvisionalAbort(telemetry);
                return generate_api.GenerateError.TokenTransactionRejected;
            }
            continue;
        }
        const token = staged[lane] orelse {
            _ = abortKvMarks(caches, marks);
            recordTokenTxnProvisionalAbort(telemetry);
            return generate_api.GenerateError.TokenTransactionRejected;
        };
        const cache = caches[lane].contiguousPtr() orelse {
            _ = abortKvMarks(caches, marks);
            recordTokenTxnProvisionalAbort(telemetry);
            return generate_api.GenerateError.TokenTransactionRejected;
        };
        const concrete_mark: ?kv.RowTxnMark = if (marks[lane]) |mark|
            switch (mark) {
                .contiguous => |value| value,
                else => {
                    _ = abortKvMarks(caches, marks);
                    recordTokenTxnProvisionalAbort(telemetry);
                    return generate_api.GenerateError.TokenTransactionRejected;
                },
            }
        else
            null;
        lane_stages[live_count] = .{
            .lane_index = @intCast(lane),
            .prompt_len = requests[lane].prompt.len,
            .cache = cache,
            .kv_mark = concrete_mark,
            .rng_state = &prngs[lane].s,
            .rng_after = token.rng_after,
            .sampling_calls = &sampling_calls[lane],
            .sampling_calls_after = token.sampling_calls_after,
            .output = result.storage[lane],
            .output_len = &result.lengths[lane],
            .token_id = token.token_id,
            .terminal = token.terminal,
        };
        live_count += 1;
    }

    var batch = token_txn.Batch.begin(
        session,
        lane_stages[0..live_count],
    ) catch {
        const clean = abortKvMarks(caches, marks);
        recordTokenTxnProvisionalAbort(telemetry);
        if (!clean) return generate_api.GenerateError.TokenTransactionRejected;
        return generate_api.GenerateError.TokenTransactionRejected;
    };
    // Batch now exclusively owns every live mark and rolls them back on all
    // prepare/commit failures. Clearing the caller copy prevents a second
    // abort path from touching an already transferred generation.
    marks.* = [_]?RuntimeKvMark{null} ** width;

    batch.prepare(publication.sink) catch |err| {
        if (telemetry) |out| {
            out.token_txn_aborts +|= 1;
            if (err == error.SinkRejected or err == error.InvalidPrepareAck)
                out.token_txn_sink_rejects +|= 1;
        }
        return generate_api.GenerateError.TokenTransactionRejected;
    };
    const receipt = batch.commit() catch {
        if (telemetry) |out| out.token_txn_aborts +|= 1;
        return generate_api.GenerateError.TokenTransactionRejected;
    };

    for (active, 0..) |*is_active, lane| {
        const lane_bit = @as(u8, 1) << @intCast(lane);
        if (receipt.proposal.live_mask & lane_bit != 0)
            is_active.* = !receipt.proposal.lanes[lane].terminal;
    }
    if (telemetry) |out| {
        out.token_txn_commits +|= 1;
        out.token_txn_lane_commits +|= receipt.proposal.live_lane_count;
        out.token_txn_first_token_commits +|=
            @intFromBool(receipt.proposal.transaction_sequence == 0);
        for (receipt.proposal.lanes) |lane|
            out.token_txn_kv_row_commits +|=
                @intFromBool(lane.has_kv_transition);
        out.token_txn_last_sequence = receipt.proposal.transaction_sequence;
    }
}

fn commitPagedTokenWave(
    session: *paged_token_txn.Session,
    publication: PagedTokenTxnPublication,
    requests: [width]Request,
    caches: *[width]RuntimeKvCache,
    marks: *[width]?RuntimeKvMark,
    staged: *const [width]?StagedToken,
    prngs: *[width]std.Random.DefaultPrng,
    sampling_calls: *[width]usize,
    result: *Result,
    active: *[width]bool,
    telemetry: ?*Telemetry,
) generate_api.GenerateError!void {
    var lane_stages: [width]paged_token_txn.LaneStage = undefined;
    var live_count: usize = 0;
    for (active, 0..) |is_active, lane| {
        if (!is_active) {
            if (marks[lane] != null or staged[lane] != null) {
                _ = abortKvMarks(caches, marks);
                recordTokenTxnProvisionalAbort(telemetry);
                return generate_api.GenerateError.TokenTransactionRejected;
            }
            continue;
        }
        const token = staged[lane] orelse {
            _ = abortKvMarks(caches, marks);
            recordTokenTxnProvisionalAbort(telemetry);
            return generate_api.GenerateError.TokenTransactionRejected;
        };
        const cache = caches[lane].pagedPtr() orelse {
            _ = abortKvMarks(caches, marks);
            recordTokenTxnProvisionalAbort(telemetry);
            return generate_api.GenerateError.TokenTransactionRejected;
        };
        const concrete_mark: ?paged_kv.RowTxnMark = if (marks[lane]) |mark|
            switch (mark) {
                .paged16_required => |value| value,
                else => {
                    _ = abortKvMarks(caches, marks);
                    recordTokenTxnProvisionalAbort(telemetry);
                    return generate_api.GenerateError.TokenTransactionRejected;
                },
            }
        else
            null;
        lane_stages[live_count] = .{
            .lane_index = @intCast(lane),
            .prompt_len = requests[lane].prompt.len,
            .cache = cache,
            .kv_mark = concrete_mark,
            .rng_state = &prngs[lane].s,
            .rng_after = token.rng_after,
            .sampling_calls = &sampling_calls[lane],
            .sampling_calls_after = token.sampling_calls_after,
            .output = result.storage[lane],
            .output_len = &result.lengths[lane],
            .token_id = token.token_id,
            .terminal = token.terminal,
        };
        live_count += 1;
    }

    var batch = paged_token_txn.Batch.begin(
        session,
        lane_stages[0..live_count],
    ) catch {
        const clean = abortKvMarks(caches, marks);
        recordTokenTxnProvisionalAbort(telemetry);
        if (!clean)
            return generate_api.GenerateError.TokenTransactionRejected;
        return generate_api.GenerateError.TokenTransactionRejected;
    };
    marks.* = [_]?RuntimeKvMark{null} ** width;

    batch.prepare(publication.sink) catch |err| {
        if (telemetry) |out| {
            out.token_txn_aborts +|= 1;
            if (err == error.SinkRejected or err == error.InvalidPrepareAck)
                out.token_txn_sink_rejects +|= 1;
        }
        return generate_api.GenerateError.TokenTransactionRejected;
    };
    const receipt = batch.commit() catch {
        if (telemetry) |out| out.token_txn_aborts +|= 1;
        return generate_api.GenerateError.TokenTransactionRejected;
    };

    for (active, 0..) |*is_active, lane| {
        const lane_bit = @as(u8, 1) << @intCast(lane);
        if (receipt.proposal.live_mask & lane_bit != 0)
            is_active.* = !receipt.proposal.lanes[lane].terminal;
    }
    if (telemetry) |out| {
        out.token_txn_commits +|= 1;
        out.token_txn_lane_commits +|= receipt.proposal.live_lane_count;
        out.token_txn_first_token_commits +|=
            @intFromBool(receipt.proposal.transaction_sequence == 0);
        for (receipt.proposal.lanes) |lane| {
            const committed_row: usize =
                @intFromBool(lane.has_kv_transition);
            out.token_txn_kv_row_commits +|= committed_row;
            out.paged_root_commits +|= committed_row;
        }
        out.token_txn_last_sequence = receipt.proposal.transaction_sequence;
    }
}

fn commitPagedElasticTokenWave(
    session: *paged_elastic_token_txn.Session,
    publication: PagedElasticTokenTxnPublication,
    requests: [width]Request,
    caches: *[width]RuntimeKvCache,
    marks: *[width]?RuntimeKvMark,
    staged: *const [width]?StagedToken,
    prngs: *[width]std.Random.DefaultPrng,
    sampling_calls: *[width]usize,
    result: *Result,
    active: *[width]bool,
    telemetry: ?*Telemetry,
) generate_api.GenerateError!void {
    var lane_stages: [width]paged_elastic_token_txn.LaneStage = undefined;
    var live_count: usize = 0;
    for (active, 0..) |is_active, lane| {
        if (!is_active) {
            if (marks[lane] != null or staged[lane] != null) {
                _ = abortKvMarks(caches, marks);
                recordTokenTxnProvisionalAbort(telemetry);
                return generate_api.GenerateError.TokenTransactionRejected;
            }
            continue;
        }
        const token = staged[lane] orelse {
            _ = abortKvMarks(caches, marks);
            recordTokenTxnProvisionalAbort(telemetry);
            return generate_api.GenerateError.TokenTransactionRejected;
        };
        const cache = caches[lane].pagedPtr() orelse {
            _ = abortKvMarks(caches, marks);
            recordTokenTxnProvisionalAbort(telemetry);
            return generate_api.GenerateError.TokenTransactionRejected;
        };
        const concrete_mark: ?paged_kv.RowTxnMark = if (marks[lane]) |mark|
            switch (mark) {
                .paged16_required => |value| value,
                else => {
                    _ = abortKvMarks(caches, marks);
                    recordTokenTxnProvisionalAbort(telemetry);
                    return generate_api.GenerateError.TokenTransactionRejected;
                },
            }
        else
            null;
        lane_stages[live_count] = .{
            .lane_index = @intCast(lane),
            .prompt_len = requests[lane].prompt.len,
            .cache = cache,
            .kv_mark = concrete_mark,
            .rng_state = &prngs[lane].s,
            .rng_after = token.rng_after,
            .sampling_calls = &sampling_calls[lane],
            .sampling_calls_after = token.sampling_calls_after,
            .output = result.storage[lane],
            .output_len = &result.lengths[lane],
            .token_id = token.token_id,
            .terminal = token.terminal,
        };
        live_count += 1;
    }

    var batch = paged_elastic_token_txn.Batch.begin(
        session,
        lane_stages[0..live_count],
    ) catch {
        const clean = abortKvMarks(caches, marks);
        recordTokenTxnProvisionalAbort(telemetry);
        if (!clean)
            return generate_api.GenerateError.TokenTransactionRejected;
        return generate_api.GenerateError.TokenTransactionRejected;
    };
    marks.* = [_]?RuntimeKvMark{null} ** width;

    batch.prepare(publication.sink) catch |err| {
        if (telemetry) |out| {
            out.token_txn_aborts +|= 1;
            if (err == error.SinkRejected or err == error.InvalidPrepareAck)
                out.token_txn_sink_rejects +|= 1;
        }
        return generate_api.GenerateError.TokenTransactionRejected;
    };
    const receipt = batch.commit() catch {
        if (telemetry) |out| out.token_txn_aborts +|= 1;
        return generate_api.GenerateError.TokenTransactionRejected;
    };

    for (active, 0..) |*is_active, lane| {
        const lane_bit = @as(u8, 1) << @intCast(lane);
        if (receipt.proposal.live_mask & lane_bit != 0)
            is_active.* = !receipt.proposal.lanes[lane].terminal;
    }
    if (telemetry) |out| {
        out.token_txn_commits +|= 1;
        out.token_txn_lane_commits +|= receipt.proposal.live_lane_count;
        out.token_txn_first_token_commits +|=
            @intFromBool(receipt.proposal.transaction_sequence == 0);
        for (receipt.proposal.lanes) |lane| {
            const committed_row: usize =
                @intFromBool(lane.has_kv_transition);
            out.token_txn_kv_row_commits +|= committed_row;
            out.paged_root_commits +|= committed_row;
        }
        out.token_txn_last_sequence = receipt.proposal.transaction_sequence;
        out.paged_kv_child_current_bytes = @intCast(
            receipt.proposal.resident_payload_bytes,
        );
        out.paged_kv_child_peak_bytes = @max(
            out.paged_kv_child_peak_bytes,
            out.paged_kv_child_current_bytes,
        );
    }
}

fn commitPagedLeaseTokenWave(
    session: *paged_lease_token_txn.Session,
    publication: PagedLeaseTokenTxnPublication,
    requests: [width]Request,
    coordinators: *[width]leased_paged_kv.LeasedPagedKVCache,
    marks: *[width]?RuntimeKvMark,
    staged: *const [width]?StagedToken,
    prngs: *[width]std.Random.DefaultPrng,
    sampling_calls: *[width]usize,
    result: *Result,
    active: *[width]bool,
    telemetry: ?*Telemetry,
) generate_api.GenerateError!paged_lease_token_txn.CommitReceiptV3 {
    var lane_stages: [width]paged_lease_token_txn.LaneStage = undefined;
    var live_count: usize = 0;
    for (active, 0..) |is_active, lane| {
        if (!is_active) {
            if (marks[lane] != null or staged[lane] != null) {
                _ = abortLeasedKvMarks(coordinators, marks);
                recordTokenTxnProvisionalAbort(telemetry);
                return generate_api.GenerateError.TokenTransactionRejected;
            }
            continue;
        }
        const token = staged[lane] orelse {
            _ = abortLeasedKvMarks(coordinators, marks);
            recordTokenTxnProvisionalAbort(telemetry);
            return generate_api.GenerateError.TokenTransactionRejected;
        };
        const concrete_txn: ?leased_paged_kv.LeasedRowTxnV1 = if (marks[lane]) |mark|
            switch (mark) {
                .leased_paged16 => |value| value,
                else => {
                    _ = abortLeasedKvMarks(coordinators, marks);
                    recordTokenTxnProvisionalAbort(telemetry);
                    return generate_api.GenerateError.TokenTransactionRejected;
                },
            }
        else
            null;
        lane_stages[live_count] = .{
            .lane_index = @intCast(lane),
            .prompt_len = requests[lane].prompt.len,
            .coordinator = &coordinators[lane],
            .leased_row_txn = concrete_txn,
            .rng_state = &prngs[lane].s,
            .rng_after = token.rng_after,
            .sampling_calls = &sampling_calls[lane],
            .sampling_calls_after = token.sampling_calls_after,
            .output = result.storage[lane],
            .output_len = &result.lengths[lane],
            .token_id = token.token_id,
            .terminal_reason = stagedTerminalReason(requests[lane], token),
        };
        live_count += 1;
    }

    var batch = paged_lease_token_txn.Batch.begin(
        session,
        lane_stages[0..live_count],
    ) catch {
        const clean = abortLeasedKvMarks(coordinators, marks);
        recordTokenTxnProvisionalAbort(telemetry);
        if (!clean)
            return generate_api.GenerateError.TokenTransactionRejected;
        return generate_api.GenerateError.TokenTransactionRejected;
    };
    marks.* = [_]?RuntimeKvMark{null} ** width;
    batch.prepare(publication.sink) catch |err| {
        if (telemetry) |out| {
            out.token_txn_aborts +|= 1;
            if (err == error.SinkRejected or err == error.InvalidPrepareAck)
                out.token_txn_sink_rejects +|= 1;
        }
        return generate_api.GenerateError.TokenTransactionRejected;
    };
    const receipt = batch.commit() catch {
        if (telemetry) |out| out.token_txn_aborts +|= 1;
        return generate_api.GenerateError.TokenTransactionRejected;
    };

    for (active, 0..) |*is_active, lane| {
        const lane_bit = @as(u8, 1) << @intCast(lane);
        if (receipt.proposal.live_mask & lane_bit != 0)
            is_active.* = receipt.proposal.lanes[lane].terminal_reason == null;
    }
    if (telemetry) |out| {
        out.token_txn_commits +|= 1;
        out.token_txn_lane_commits +|= receipt.proposal.live_lane_count;
        out.token_txn_first_token_commits +|=
            @intFromBool(receipt.proposal.transaction_sequence == 0);
        for (receipt.proposal.lanes) |lane| {
            const committed_row: usize = @intFromBool(lane.has_kv_transition);
            out.token_txn_kv_row_commits +|= committed_row;
            out.paged_root_commits +|= committed_row;
            out.paged_lease_terminal_lanes +|=
                @intFromBool(lane.terminal_reason != null);
        }
        out.token_txn_last_sequence = receipt.proposal.transaction_sequence;
        out.paged_lease_retained_payload_bytes = @intCast(
            receipt.proposal.tree.current.kv_bytes,
        );
        out.paged_lease_peak_payload_bytes = @max(
            out.paged_lease_peak_payload_bytes,
            out.paged_lease_retained_payload_bytes,
        );
    }
    return receipt;
}

fn reclaimPublishedLeaseTerminals(
    session: *paged_lease_token_txn.Session,
    receipt: paged_lease_token_txn.CommitReceiptV3,
    policy: LeaseReclaimPolicy,
    telemetry: ?*Telemetry,
) generate_api.GenerateError!u8 {
    if (policy == .retain_until_teardown) return 0;
    var reclaimed_mask: u8 = 0;
    for (receipt.terminal_seals, 0..) |maybe_seal, lane| {
        const seal = maybe_seal orelse continue;
        const freed = session.beginLaneReclaim(lane, seal) catch
            return generate_api.GenerateError.PostPublicationReclaimPending;
        const reclaim = session.commitLaneReclaimAfterFree(
            lane,
            freed,
        ) catch return generate_api.GenerateError.PostPublicationReclaimPending;
        reclaimed_mask |= @as(u8, 1) << @intCast(lane);
        if (telemetry) |out| {
            out.paged_lease_reclaimed_lanes +|= 1;
            out.paged_lease_reclaimed_payload_bytes +|=
                std.math.cast(usize, freed.payload_bytes) orelse
                return generate_api.GenerateError.PostPublicationReclaimPending;
            out.paged_lease_retained_payload_bytes =
                std.math.cast(usize, reclaim.tree_after.current.kv_bytes) orelse
                return generate_api.GenerateError.PostPublicationReclaimPending;
        }
    }
    return reclaimed_mask;
}

fn observePagedLeaseWave(
    observer: ?PagedLeaseWaveObserver,
    bank: *resource_bank.Bank,
    tree: resource_bank.LeaseTreeV1,
    receipt: *const paged_lease_token_txn.CommitReceiptV3,
    active: [width]bool,
    policy: LeaseReclaimPolicy,
    reclaimed_mask: u8,
) generate_api.GenerateError!void {
    const selected = observer orelse return;
    var terminal_mask: u8 = 0;
    for (receipt.terminal_seals, 0..) |seal, lane| if (seal != null) {
        terminal_mask |= @as(u8, 1) << @intCast(lane);
    };
    if (reclaimed_mask & ~terminal_mask != 0 or
        (policy == .retain_until_teardown and reclaimed_mask != 0) or
        (policy == .terminal_immediate and reclaimed_mask != terminal_mask))
        return generate_api.GenerateError.TokenTransactionRejected;
    const evidence: PagedLeaseWaveEvidenceV1 = .{
        .request_epoch = receipt.proposal.request_epoch,
        .transaction_sequence = receipt.proposal.transaction_sequence,
        .next_sequence = receipt.proposal.transaction_sequence + 1,
        .published_live_mask = receipt.proposal.live_mask,
        .terminal_mask = terminal_mask,
        .remaining_live_mask = activeLaneMask(active),
        .reclaimed_mask = reclaimed_mask,
        .reclaim_policy = policy,
        .proposal_sha256 = receipt.proposal_sha256,
        .commit_sha256 = receipt.commit_sha256,
        .tree = pagedLeaseTreeState(tree),
        .bank = bank.snapshotV3() catch
            return generate_api.GenerateError.TokenTransactionRejected,
    };
    selected.observe(selected.context, &evidence);
}

fn mapPagedLeaseRuntimeError(
    session: *const paged_lease_token_txn.Session,
    err: generate_api.GenerateError,
) generate_api.GenerateError {
    if (session.next_sequence != 0 and
        err != generate_api.GenerateError.PostPublicationReclaimPending and
        err != generate_api.GenerateError.PostPublicationGenerationInterrupted)
        return generate_api.GenerateError.PostPublicationGenerationInterrupted;
    return err;
}

const AttentionLaneJob = struct {
    q: []f32,
    k: []f32,
    v: []f32,
    out: []f32,
    dim: usize,
    kv_dim: usize,
    kv_seq: usize,
    num_heads: usize,
    head_dim: usize,
    rope_theta: f32,
    num_kv_heads: usize,
    paged_prefix: ?paged_kv.LayerPrefix = null,
    mode: AttentionMode = .serial,
    shared_kv_tiles: usize = 0,
    err: ?tensor.TensorError = null,
    ran: if (builtin.is_test) bool else void = if (builtin.is_test) false else {},

    fn run(job: *@This()) void {
        if (builtin.is_test) job.ran = true;
        var q_shape: [2]usize = undefined;
        var out_shape: [2]usize = undefined;
        const q_view = view(job.q, &q_shape, 1, job.dim);
        const out_view = view(job.out, &out_shape, 1, job.dim);
        if (job.paged_prefix) |prefix| {
            if (job.mode != .serial or prefix.positions != job.kv_seq) {
                job.err = tensor.TensorError.ShapeMismatch;
                return;
            }
            paged_attention.attentionMultiHead(
                q_view,
                prefix,
                out_view,
                job.num_heads,
                job.head_dim,
                job.rope_theta,
                job.num_kv_heads,
            ) catch {
                job.err = tensor.TensorError.ShapeMismatch;
            };
            return;
        }
        var k_shape: [2]usize = undefined;
        var v_shape: [2]usize = undefined;
        const k_view = view(job.k, &k_shape, job.kv_seq, job.kv_dim);
        const v_view = view(job.v, &v_shape, job.kv_seq, job.kv_dim);
        switch (job.mode) {
            .serial => forward.attentionMultiHead(
                q_view,
                k_view,
                v_view,
                out_view,
                job.num_heads,
                job.head_dim,
                job.rope_theta,
                job.num_kv_heads,
            ) catch |err| {
                job.err = err;
            },
            .shared_kv_required => {
                var plan = forward.SharedKvAttentionPlan.init(
                    q_view,
                    k_view,
                    v_view,
                    out_view,
                    job.num_heads,
                    job.head_dim,
                    job.num_kv_heads,
                    1,
                ) catch |err| {
                    job.err = err;
                    return;
                };
                if (!plan.usesFusedSharedKv()) {
                    job.err = tensor.TensorError.ShapeMismatch;
                    return;
                }
                forward.SharedKvAttentionPlan.run(
                    @ptrCast(&plan),
                    0,
                ) catch |err| {
                    job.err = err;
                    return;
                };
                job.shared_kv_tiles = plan.tile_count;
            },
        }
    }
};

fn recordLaneAttentionCompletion(
    jobs: []const AttentionLaneJob,
    telemetry: ?*Telemetry,
) void {
    const out = telemetry orelse return;
    for (jobs) |job| {
        if (job.shared_kv_tiles == 0) continue;
        out.shared_kv_attention_lane_dispatches +|= 1;
        out.shared_kv_attention_tiles +|= job.shared_kv_tiles;
    }
}

fn runJoinedAttentionJob(
    job: *AttentionLaneJob,
    wait_group: *std.Thread.WaitGroup,
) void {
    defer wait_group.finish();
    job.run();
}

/// Parallelize across independent requests, never within a lane. Every task
/// owns disjoint Q/K/V/output storage, so its floating-point operation order is
/// exactly the serial `attentionMultiHead` order. Errors are inspected only
/// after every submitted task has joined; no downstream projection observes a
/// partially completed attention cohort.
fn runLaneAttention(
    pool: *std.Thread.Pool,
    jobs: []AttentionLaneJob,
    telemetry: ?*Telemetry,
) generate_api.GenerateError!void {
    if (jobs.len == 0) return;
    if (jobs.len == 1) {
        jobs[0].run();
        if (jobs[0].err != null)
            return generate_api.GenerateError.ForwardFailed;
        recordLaneAttentionCompletion(jobs, telemetry);
        return;
    }

    var wait_group: std.Thread.WaitGroup = .{};
    wait_group.startMany(jobs.len);
    for (jobs, 0..) |*job, index| {
        pool.spawn(runJoinedAttentionJob, .{ job, &wait_group }) catch {
            // Retire the failed and never-attempted credits, then drain every
            // prior enqueue before stack-backed jobs and the WG leave scope.
            for (index..jobs.len) |_| wait_group.finish();
            pool.waitAndWork(&wait_group);
            if (telemetry) |out| out.lane_attention_enqueue_rejects +|= 1;
            return generate_api.GenerateError.OutOfMemory;
        };
    }
    if (telemetry) |out| {
        out.lane_parallel_attention_dispatches +|= 1;
        out.lane_parallel_attention_tasks +|= jobs.len;
    }
    pool.waitAndWork(&wait_group);
    for (jobs) |job| if (job.err != null)
        return generate_api.GenerateError.ForwardFailed;
    recordLaneAttentionCompletion(jobs, telemetry);
}

const StateHashJob = struct {
    destination: *generate_api.GenerationStateTelemetry,
    cache: *kv.KVCache,
    tokens: []const u32,
    sampling_calls: usize,
    prng: *const std.Random.DefaultPrng,

    fn run(self: *@This()) void {
        generate_api.recordCompletedGenerationState(
            self.destination,
            self.cache,
            self.tokens,
            self.sampling_calls,
            self.prng,
        );
    }
};

fn runJoinedStateHash(
    job: *StateHashJob,
    wait_group: *std.Thread.WaitGroup,
) void {
    defer wait_group.finish();
    job.run();
}

/// Hash four independent final states with the same four-participant budget
/// used by the cohort graph. All jobs own disjoint KV/output/telemetry state;
/// enqueue failure drains prior jobs and rejects the cohort rather than
/// falling back to a serial postlude hidden inside the measured interval.
fn recordLaneStatesParallel(
    pool: *std.Thread.Pool,
    caches: *[width]kv.KVCache,
    result: *const Result,
    sampling_calls: [width]usize,
    prngs: *const [width]std.Random.DefaultPrng,
    telemetry: ?*Telemetry,
) generate_api.GenerateError!void {
    const out = telemetry orelse return;
    var jobs: [width]StateHashJob = undefined;
    for (&jobs, 0..) |*job, lane| {
        job.* = .{
            .destination = &out.lane_states[lane],
            .cache = &caches[lane],
            .tokens = result.tokens(lane),
            .sampling_calls = sampling_calls[lane],
            .prng = &prngs[lane],
        };
    }

    var wait_group: std.Thread.WaitGroup = .{};
    wait_group.startMany(width);
    for (&jobs, 0..) |*job, index| {
        pool.spawn(runJoinedStateHash, .{ job, &wait_group }) catch {
            for (index..width) |_| wait_group.finish();
            pool.waitAndWork(&wait_group);
            out.state_hash_enqueue_rejects +|= 1;
            return generate_api.GenerateError.OutOfMemory;
        };
    }
    pool.waitAndWork(&wait_group);
    out.state_hash_parallel_dispatches +|= 1;
    out.state_hash_tasks +|= width;
}

fn recordRuntimeContiguousStatesParallel(
    pool: *std.Thread.Pool,
    caches: *[width]RuntimeKvCache,
    result: *const Result,
    sampling_calls: [width]usize,
    prngs: *const [width]std.Random.DefaultPrng,
    telemetry: ?*Telemetry,
) generate_api.GenerateError!void {
    const out = telemetry orelse return;
    var jobs: [width]StateHashJob = undefined;
    for (&jobs, 0..) |*job, lane| {
        job.* = .{
            .destination = &out.lane_states[lane],
            .cache = caches[lane].contiguousPtr() orelse
                return generate_api.GenerateError.ForwardFailed,
            .tokens = result.tokens(lane),
            .sampling_calls = sampling_calls[lane],
            .prng = &prngs[lane],
        };
    }
    var wait_group: std.Thread.WaitGroup = .{};
    wait_group.startMany(width);
    for (&jobs, 0..) |*job, index| {
        pool.spawn(runJoinedStateHash, .{ job, &wait_group }) catch {
            for (index..width) |_| wait_group.finish();
            pool.waitAndWork(&wait_group);
            out.state_hash_enqueue_rejects +|= 1;
            return generate_api.GenerateError.OutOfMemory;
        };
    }
    pool.waitAndWork(&wait_group);
    out.state_hash_parallel_dispatches +|= 1;
    out.state_hash_tasks +|= width;
}

const PreparedStateHashJob = struct {
    destination: *generate_api.GenerationStateTelemetry,
    cache: *kv.KVCache,
    kv_positions: usize,
    committed_tokens: []const u32,
    appended_token: ?u32,
    sampling_calls: usize,
    rng_state: token_txn.RngState,

    fn run(self: *@This()) void {
        self.destination.* = .{
            .complete = true,
            .kv_positions = self.kv_positions,
            .published_tokens = self.committed_tokens.len +
                @intFromBool(self.appended_token != null),
            .sampling_calls = self.sampling_calls,
            .kv_sha256 = generate_api.logicalKvPrefixSha256(
                self.cache,
                self.kv_positions,
            ),
            .output_sha256 = if (self.appended_token) |token|
                generate_api.tokenSequenceAppendedSha256(
                    self.committed_tokens,
                    token,
                )
            else
                generate_api.tokenSequenceSha256(self.committed_tokens),
            .rng_state = self.rng_state,
        };
    }
};

fn runJoinedPreparedStateHash(
    job: *PreparedStateHashJob,
    wait_group: *std.Thread.WaitGroup,
) void {
    defer wait_group.finish();
    job.run();
}

fn tokenWaveTerminatesSession(
    active: [width]bool,
    staged: *const [width]?StagedToken,
) bool {
    var have_live = false;
    for (active, 0..) |is_active, lane| {
        if (!is_active) continue;
        have_live = true;
        const token = staged[lane] orelse return false;
        if (!token.terminal) return false;
    }
    return have_live;
}

/// Prepare all terminal state receipts while the final live wave is still
/// private. Enqueue failure therefore occurs before SinkV1 can observe the
/// terminal transaction. The returned values are copied into public telemetry
/// only after the same transaction commits.
fn prepareTerminalLaneStatesParallel(
    pool: *std.Thread.Pool,
    requests: [width]Request,
    caches: *[width]kv.KVCache,
    result: *const Result,
    active: [width]bool,
    staged: *const [width]?StagedToken,
    sampling_calls: [width]usize,
    prngs: *const [width]std.Random.DefaultPrng,
    destination: *[width]generate_api.GenerationStateTelemetry,
) generate_api.GenerateError!void {
    if (!tokenWaveTerminatesSession(active, staged))
        return generate_api.GenerateError.TokenTransactionRejected;

    var jobs: [width]PreparedStateHashJob = undefined;
    for (&jobs, 0..) |*job, lane| {
        if (active[lane]) {
            const token = staged[lane].?;
            const output_before = result.lengths[lane];
            const has_kv_transition = output_before != 0;
            const kv_positions = std.math.add(
                usize,
                caches[lane].len,
                @intFromBool(has_kv_transition),
            ) catch return generate_api.GenerateError.TokenTransactionRejected;
            const expected_positions = std.math.add(
                usize,
                requests[lane].prompt.len,
                output_before,
            ) catch return generate_api.GenerateError.TokenTransactionRejected;
            if (kv_positions != expected_positions)
                return generate_api.GenerateError.TokenTransactionRejected;
            job.* = .{
                .destination = &destination[lane],
                .cache = &caches[lane],
                .kv_positions = kv_positions,
                .committed_tokens = result.tokens(lane),
                .appended_token = token.token_id,
                .sampling_calls = token.sampling_calls_after,
                .rng_state = token.rng_after,
            };
        } else {
            job.* = .{
                .destination = &destination[lane],
                .cache = &caches[lane],
                .kv_positions = caches[lane].len,
                .committed_tokens = result.tokens(lane),
                .appended_token = null,
                .sampling_calls = sampling_calls[lane],
                .rng_state = prngs[lane].s,
            };
        }
    }

    var wait_group: std.Thread.WaitGroup = .{};
    wait_group.startMany(width);
    for (&jobs, 0..) |*job, index| {
        pool.spawn(runJoinedPreparedStateHash, .{ job, &wait_group }) catch {
            for (index..width) |_| wait_group.finish();
            pool.waitAndWork(&wait_group);
            return generate_api.GenerateError.OutOfMemory;
        };
    }
    pool.waitAndWork(&wait_group);
}

fn prepareRuntimeContiguousTerminalLaneStatesParallel(
    pool: *std.Thread.Pool,
    requests: [width]Request,
    caches: *[width]RuntimeKvCache,
    result: *const Result,
    active: [width]bool,
    staged: *const [width]?StagedToken,
    sampling_calls: [width]usize,
    prngs: *const [width]std.Random.DefaultPrng,
    destination: *[width]generate_api.GenerationStateTelemetry,
) generate_api.GenerateError!void {
    if (!tokenWaveTerminatesSession(active, staged))
        return generate_api.GenerateError.TokenTransactionRejected;
    var jobs: [width]PreparedStateHashJob = undefined;
    for (&jobs, 0..) |*job, lane| {
        const cache = caches[lane].contiguousPtr() orelse
            return generate_api.GenerateError.TokenTransactionRejected;
        if (active[lane]) {
            const token = staged[lane].?;
            const output_before = result.lengths[lane];
            const has_kv_transition = output_before != 0;
            const kv_positions = std.math.add(
                usize,
                cache.len,
                @intFromBool(has_kv_transition),
            ) catch return generate_api.GenerateError.TokenTransactionRejected;
            const expected_positions = std.math.add(
                usize,
                requests[lane].prompt.len,
                output_before,
            ) catch return generate_api.GenerateError.TokenTransactionRejected;
            if (kv_positions != expected_positions)
                return generate_api.GenerateError.TokenTransactionRejected;
            job.* = .{
                .destination = &destination[lane],
                .cache = cache,
                .kv_positions = kv_positions,
                .committed_tokens = result.tokens(lane),
                .appended_token = token.token_id,
                .sampling_calls = token.sampling_calls_after,
                .rng_state = token.rng_after,
            };
        } else {
            job.* = .{
                .destination = &destination[lane],
                .cache = cache,
                .kv_positions = cache.len,
                .committed_tokens = result.tokens(lane),
                .appended_token = null,
                .sampling_calls = sampling_calls[lane],
                .rng_state = prngs[lane].s,
            };
        }
    }
    var wait_group: std.Thread.WaitGroup = .{};
    wait_group.startMany(width);
    for (&jobs, 0..) |*job, index| {
        pool.spawn(runJoinedPreparedStateHash, .{ job, &wait_group }) catch {
            for (index..width) |_| wait_group.finish();
            pool.waitAndWork(&wait_group);
            return generate_api.GenerateError.OutOfMemory;
        };
    }
    pool.waitAndWork(&wait_group);
}

const PagedPreparedStateHashJob = struct {
    destination: *generate_api.GenerationStateTelemetry,
    cache: *paged_kv.PagedKVCache,
    mark: ?paged_kv.RowTxnMark,
    kv_positions: usize,
    committed_tokens: []const u32,
    appended_token: ?u32,
    sampling_calls: usize,
    rng_state: token_txn.RngState,
    failed: bool = false,

    fn run(self: *@This()) void {
        const digest = if (self.mark) |mark|
            self.cache.logicalKvTxnSha256(mark) catch {
                self.failed = true;
                return;
            }
        else
            self.cache.logicalKvSha256() catch {
                self.failed = true;
                return;
            };
        self.destination.* = .{
            .complete = true,
            .kv_positions = self.kv_positions,
            .published_tokens = self.committed_tokens.len +
                @intFromBool(self.appended_token != null),
            .sampling_calls = self.sampling_calls,
            .kv_sha256 = digest,
            .output_sha256 = if (self.appended_token) |token|
                generate_api.tokenSequenceAppendedSha256(
                    self.committed_tokens,
                    token,
                )
            else
                generate_api.tokenSequenceSha256(self.committed_tokens),
            .rng_state = self.rng_state,
        };
    }
};

fn runJoinedPagedPreparedStateHash(
    job: *PagedPreparedStateHashJob,
    wait_group: *std.Thread.WaitGroup,
) void {
    defer wait_group.finish();
    job.run();
}

fn preparePagedTerminalLaneStatesParallel(
    pool: *std.Thread.Pool,
    requests: [width]Request,
    caches: *[width]RuntimeKvCache,
    marks: *const [width]?RuntimeKvMark,
    result: *const Result,
    active: [width]bool,
    staged: *const [width]?StagedToken,
    sampling_calls: [width]usize,
    prngs: *const [width]std.Random.DefaultPrng,
    destination: *[width]generate_api.GenerationStateTelemetry,
) generate_api.GenerateError!void {
    if (!tokenWaveTerminatesSession(active, staged))
        return generate_api.GenerateError.TokenTransactionRejected;
    var jobs: [width]PagedPreparedStateHashJob = undefined;
    for (&jobs, 0..) |*job, lane| {
        const cache = caches[lane].pagedPtr() orelse
            return generate_api.GenerateError.TokenTransactionRejected;
        var concrete_mark: ?paged_kv.RowTxnMark = null;
        if (marks[lane]) |runtime_mark| concrete_mark = switch (runtime_mark) {
            .paged16_required => |value| value,
            else => return generate_api.GenerateError.TokenTransactionRejected,
        };
        if (active[lane]) {
            const token = staged[lane].?;
            const output_before = result.lengths[lane];
            const has_kv_transition = output_before != 0;
            if (has_kv_transition != (concrete_mark != null))
                return generate_api.GenerateError.TokenTransactionRejected;
            const kv_positions = std.math.add(
                usize,
                cache.len,
                @intFromBool(has_kv_transition),
            ) catch return generate_api.GenerateError.TokenTransactionRejected;
            const expected_positions = std.math.add(
                usize,
                requests[lane].prompt.len,
                output_before,
            ) catch return generate_api.GenerateError.TokenTransactionRejected;
            if (kv_positions != expected_positions)
                return generate_api.GenerateError.TokenTransactionRejected;
            job.* = .{
                .destination = &destination[lane],
                .cache = cache,
                .mark = concrete_mark,
                .kv_positions = kv_positions,
                .committed_tokens = result.tokens(lane),
                .appended_token = token.token_id,
                .sampling_calls = token.sampling_calls_after,
                .rng_state = token.rng_after,
            };
        } else {
            if (concrete_mark != null)
                return generate_api.GenerateError.TokenTransactionRejected;
            job.* = .{
                .destination = &destination[lane],
                .cache = cache,
                .mark = null,
                .kv_positions = cache.len,
                .committed_tokens = result.tokens(lane),
                .appended_token = null,
                .sampling_calls = sampling_calls[lane],
                .rng_state = prngs[lane].s,
            };
        }
    }

    var wait_group: std.Thread.WaitGroup = .{};
    wait_group.startMany(width);
    for (&jobs, 0..) |*job, index| {
        pool.spawn(runJoinedPagedPreparedStateHash, .{ job, &wait_group }) catch {
            for (index..width) |_| wait_group.finish();
            pool.waitAndWork(&wait_group);
            return generate_api.GenerateError.OutOfMemory;
        };
    }
    pool.waitAndWork(&wait_group);
    for (jobs) |job| if (job.failed)
        return generate_api.GenerateError.TokenTransactionRejected;
}

fn prepareLeasedRetiringLaneStatesParallel(
    pool: *std.Thread.Pool,
    requests: [width]Request,
    caches: *[width]RuntimeKvCache,
    marks: *const [width]?RuntimeKvMark,
    result: *const Result,
    active: [width]bool,
    staged: *const [width]?StagedToken,
    destination: *[width]generate_api.GenerationStateTelemetry,
) generate_api.GenerateError!usize {
    var jobs: [width]PagedPreparedStateHashJob = undefined;
    var job_count: usize = 0;
    for (active, 0..) |is_active, lane| {
        if (!is_active) continue;
        const token = staged[lane] orelse
            return generate_api.GenerateError.TokenTransactionRejected;
        if (!token.terminal) continue;
        const cache = caches[lane].pagedPtr() orelse
            return generate_api.GenerateError.TokenTransactionRejected;
        const output_before = result.lengths[lane];
        const concrete_mark: ?paged_kv.RowTxnMark = if (marks[lane]) |runtime_mark|
            switch (runtime_mark) {
                .leased_paged16 => |value| value.mark,
                else => return generate_api.GenerateError.TokenTransactionRejected,
            }
        else
            null;
        if ((output_before != 0) != (concrete_mark != null))
            return generate_api.GenerateError.TokenTransactionRejected;
        const kv_positions = std.math.add(
            usize,
            cache.len,
            @intFromBool(concrete_mark != null),
        ) catch return generate_api.GenerateError.TokenTransactionRejected;
        const expected_positions = std.math.add(
            usize,
            requests[lane].prompt.len,
            output_before,
        ) catch return generate_api.GenerateError.TokenTransactionRejected;
        if (kv_positions != expected_positions)
            return generate_api.GenerateError.TokenTransactionRejected;
        jobs[job_count] = .{
            .destination = &destination[lane],
            .cache = cache,
            .mark = concrete_mark,
            .kv_positions = kv_positions,
            .committed_tokens = result.tokens(lane),
            .appended_token = token.token_id,
            .sampling_calls = token.sampling_calls_after,
            .rng_state = token.rng_after,
        };
        job_count += 1;
    }
    if (job_count == 0) return 0;
    var wait_group: std.Thread.WaitGroup = .{};
    wait_group.startMany(job_count);
    for (jobs[0..job_count], 0..) |*job, index| {
        pool.spawn(runJoinedPagedPreparedStateHash, .{ job, &wait_group }) catch {
            for (index..job_count) |_| wait_group.finish();
            pool.waitAndWork(&wait_group);
            return generate_api.GenerateError.OutOfMemory;
        };
    }
    pool.waitAndWork(&wait_group);
    for (jobs[0..job_count]) |job| if (job.failed)
        return generate_api.GenerateError.TokenTransactionRejected;
    return job_count;
}

fn publishLeasedRetiringLaneStates(
    telemetry: ?*Telemetry,
    prepared: [width]generate_api.GenerationStateTelemetry,
    task_count: usize,
) void {
    const out = telemetry orelse return;
    if (task_count == 0) return;
    for (prepared, 0..) |state, lane| {
        if (!state.complete) continue;
        out.lane_states[lane] = state;
    }
    out.state_hash_parallel_dispatches +|= 1;
    out.state_hash_tasks +|= task_count;
}

fn publishPreparedTerminalLaneStates(
    telemetry: ?*Telemetry,
    prepared: [width]generate_api.GenerationStateTelemetry,
) void {
    const out = telemetry orelse return;
    out.lane_states = prepared;
    out.state_hash_parallel_dispatches +|= 1;
    out.state_hash_tasks +|= width;
}

const GreedyHeadCandidate = struct {
    value: f32 = -std.math.inf(f32),
    token_id: usize = std.math.maxInt(usize),
    valid: bool = false,
};

fn updateGreedyHeadCandidate(
    destination: *GreedyHeadCandidate,
    value: f32,
    token_id: usize,
) void {
    if (!destination.valid or value > destination.value or
        (value == destination.value and token_id < destination.token_id))
    {
        destination.* = .{
            .value = value,
            .token_id = token_id,
            .valid = true,
        };
    }
}

const StreamingGreedyHeadJob = struct {
    q_inputs: []const i8,
    activation_scales: []const f32,
    weights: int4_weights.Int4WeightData,
    active: [width]bool,
    in_f: usize,
    row_start: usize,
    row_end: usize,
    candidates: [width]GreedyHeadCandidate =
        [_]GreedyHeadCandidate{.{}} ** width,
    err: ?generate_api.GenerateError = null,

    fn run(self: *@This()) void {
        const packed_bytes_per_row = self.in_f / 2;
        const scales_per_row = self.in_f /
            @as(usize, self.weights.group_size);
        const row_count = self.row_end - self.row_start;
        if (row_count == 0 or row_count % 4 != 0) {
            self.err = generate_api.GenerateError.ForwardFailed;
            return;
        }
        const packed_start = self.row_start * packed_bytes_per_row;
        const scale_start = self.row_start * scales_per_row;
        var native_candidates: [width]NativeGreedyHeadCandidate = undefined;
        if (glacier_int4_gemm_neon_q8_prequant_f16scale_rows4_k16_m4_argmax_v2(
            self.q_inputs.ptr,
            self.activation_scales.ptr,
            self.weights.packed_bytes.ptr + packed_start,
            self.weights.scales_f16_rows4.ptr + scale_start,
            null,
            row_count,
            self.in_f,
            @as(usize, self.weights.group_size),
            self.row_start,
            &native_candidates,
        ) == 0) {
            self.err = generate_api.GenerateError.ForwardFailed;
            return;
        }
        for (self.active, 0..) |is_active, lane| {
            if (!is_active) continue;
            const candidate = native_candidates[lane];
            if (candidate.saw_nan != 0 or candidate.valid == 0 or
                candidate.token_id < self.row_start or
                candidate.token_id >= self.row_end)
            {
                self.err = generate_api.GenerateError.ForwardFailed;
                return;
            }
            self.candidates[lane] = .{
                .value = candidate.value,
                .token_id = candidate.token_id,
                .valid = true,
            };
        }
    }
};

fn runJoinedStreamingGreedyHead(
    job: *StreamingGreedyHeadJob,
    wait_group: *std.Thread.WaitGroup,
) void {
    defer wait_group.finish();
    job.run();
}

/// Reduce a complete B4 vocabulary head through native M4 row shards. Each
/// task keeps four canonical winners across its entire contiguous shard and
/// publishes one result per lane; no vocabulary score row is allocated.
fn runStreamingGreedyHead(
    pool: *std.Thread.Pool,
    final_hidden: tensor.Tensor,
    active: [width]bool,
    weights: int4_weights.Int4WeightData,
    q_scratch: []i8,
    scale_scratch: []f32,
    max_tasks: usize,
    destination: *[width]u32,
    telemetry: ?*Telemetry,
) generate_api.GenerateError!void {
    if (comptime builtin.cpu.arch != .aarch64)
        return generate_api.GenerateError.LogitlessGreedyUnavailable;
    if (max_tasks == 0 or max_tasks > max_thread_participants or
        final_hidden.dtype != .f32 or final_hidden.shape.len != 2 or
        final_hidden.shape[0] != width)
        return generate_api.GenerateError.ForwardFailed;
    const in_f = final_hidden.shape[1];
    if (in_f == 0 or weights.num_elements % in_f != 0)
        return generate_api.GenerateError.ForwardFailed;
    const out_f = weights.num_elements / in_f;
    if (out_f == 0 or
        out_f % 4 != 0 or in_f % 16 != 0 or
        (weights.group_size != 8 and weights.group_size != 16) or
        in_f % weights.group_size != 0 or
        weights.packed_layout != .rows4_k16 or
        weights.expanded_i8.len != 0)
        return generate_api.GenerateError.ForwardFailed;
    const packed_count = weights.num_elements / 2;
    const scale_count = weights.num_elements / weights.group_size;
    const scale_stride = int4_matmul.q8ActivationScaleCount(
        in_f,
        weights.group_size,
    );
    const q_count = std.math.mul(usize, width, in_f) catch
        return generate_api.GenerateError.ForwardFailed;
    const activation_scale_count = std.math.mul(
        usize,
        width,
        scale_stride,
    ) catch return generate_api.GenerateError.ForwardFailed;
    if (weights.packed_bytes.len < packed_count or
        weights.scales_f16_rows4.len < scale_count or
        q_scratch.len < q_count or scale_scratch.len < activation_scale_count)
        return generate_api.GenerateError.ForwardFailed;

    var active_lanes: usize = 0;
    for (active) |is_active| active_lanes += @intFromBool(is_active);
    if (active_lanes == 0) return generate_api.GenerateError.ForwardFailed;
    for (final_hidden.asF32Unsafe()[0..q_count]) |value| {
        if (!std.math.isFinite(value))
            return generate_api.GenerateError.ForwardFailed;
    }

    // This is the first write after complete shape/storage/input preflight.
    int4_matmul.quantizeQ8ActivationBatch(
        final_hidden.asF32Unsafe()[0..q_count],
        width,
        in_f,
        weights.group_size,
        q_scratch[0..q_count],
        scale_scratch[0..activation_scale_count],
    ) catch return generate_api.GenerateError.ForwardFailed;

    const row_group_count = out_f / 4;
    const task_count = @min(max_tasks, row_group_count);
    var jobs: [max_thread_participants]StreamingGreedyHeadJob = undefined;
    for (jobs[0..task_count], 0..) |*job, task_index| {
        const group_start = row_group_count * task_index / task_count;
        const group_end = row_group_count * (task_index + 1) / task_count;
        job.* = .{
            .q_inputs = q_scratch[0..q_count],
            .activation_scales = scale_scratch[0..activation_scale_count],
            .weights = weights,
            .active = active,
            .in_f = in_f,
            .row_start = group_start * 4,
            .row_end = group_end * 4,
        };
    }

    const background_jobs = task_count - 1;
    var wait_group: std.Thread.WaitGroup = .{};
    if (background_jobs != 0) wait_group.startMany(background_jobs);
    for (jobs[0..background_jobs], 0..) |*job, index| {
        pool.spawn(runJoinedStreamingGreedyHead, .{ job, &wait_group }) catch {
            for (index..background_jobs) |_| wait_group.finish();
            pool.waitAndWork(&wait_group);
            if (telemetry) |out|
                out.streaming_greedy_head_enqueue_rejects +|= 1;
            return generate_api.GenerateError.OutOfMemory;
        };
    }
    jobs[background_jobs].run();
    pool.waitAndWork(&wait_group);
    for (jobs[0..task_count]) |job| if (job.err) |err| return err;

    var selected = [_]u32{0} ** width;
    for (active, 0..) |is_active, lane| {
        if (!is_active) continue;
        var winner: GreedyHeadCandidate = .{};
        for (jobs[0..task_count]) |job| {
            const candidate = job.candidates[lane];
            if (candidate.valid)
                updateGreedyHeadCandidate(
                    &winner,
                    candidate.value,
                    candidate.token_id,
                );
        }
        if (!winner.valid or winner.token_id >= out_f)
            return generate_api.GenerateError.ForwardFailed;
        selected[lane] = std.math.cast(u32, winner.token_id) orelse
            return generate_api.GenerateError.ForwardFailed;
    }
    destination.* = selected;

    if (telemetry) |out| {
        out.streaming_greedy_head_m4_dispatches +|= 1;
        out.streaming_greedy_head_tasks +|= task_count;
        out.streaming_greedy_head_shards +|= task_count;
        out.streaming_greedy_head_lane_candidates +|=
            active_lanes * task_count;
    }
}

const HeadDestination = union(enum) {
    none,
    materialized: tensor.Tensor,
    streaming_required: *[width]u32,
};

fn forwardLayer(
    cfg: forward.LayerConfig,
    weights: forward.LayerWeights,
    input: tensor.Tensor,
    output: tensor.Tensor,
    caches: *[width]RuntimeKvCache,
    kv_marks: ?*const [width]?RuntimeKvMark,
    leased_coordinators: ?*[width]leased_paged_kv.LeasedPagedKVCache,
    layer_index: usize,
    active: [width]bool,
    attention_mode: AttentionMode,
    pair_down_mode: PairDownMode,
    buffers: *prefill_buffers.Buffers,
    rope: *const RopeTable,
    pool: *std.Thread.Pool,
    tasks: usize,
    telemetry: ?*Telemetry,
) generate_api.GenerateError!void {
    const dim = cfg.dim;
    const hidden = cfg.hidden_dim;
    const kv_dim = cfg.num_kv_heads * cfg.head_dim;
    var s_hn: [2]usize = undefined;
    var s_q: [2]usize = undefined;
    var s_k: [2]usize = undefined;
    var s_v: [2]usize = undefined;
    var s_attn: [2]usize = undefined;
    var s_proj: [2]usize = undefined;
    var s_h: [2]usize = undefined;
    var s_mlp: [2]usize = undefined;
    var s_down: [2]usize = undefined;

    const h_norm = view(buffers.h_norm, &s_hn, width, dim);
    kernels.rmsNormF32Rows4WeightStationary(
        input,
        weights.input_norm,
        cfg.rms_eps,
        h_norm,
    ) catch
        return generate_api.GenerateError.ForwardFailed;
    const q_rows = view(buffers.q, &s_q, width, dim);
    const k_rows = view(buffers.k, &s_k, width, kv_dim);
    const v_rows = view(buffers.v, &s_v, width, kv_dim);
    const qkv_projections = [_]SharedActivationProjection{
        .{
            .weight = weights.wq_int4.?,
            .bias = weights.bq,
            .output = q_rows,
            .out_f = dim,
        },
        .{
            .weight = weights.wk_int4.?,
            .bias = weights.bk,
            .output = k_rows,
            .out_f = kv_dim,
        },
        .{
            .weight = weights.wv_int4.?,
            .bias = weights.bv,
            .output = v_rows,
            .out_f = kv_dim,
        },
    };
    const qkv_execution = try projectSharedActivation(
        pool,
        h_norm,
        dim,
        &qkv_projections,
        buffers,
        tasks,
    );
    if (telemetry) |out| {
        out.qkv_projection_dispatches +|= qkv_projections.len;
        out.qkv_activation_quantizations +|= qkv_execution.quantizations;
        out.qkv_quantization_reuses +|=
            qkv_projections.len - qkv_execution.quantizations;
        out.qkv_projection_waves +|= qkv_execution.quantizations;
        out.qkv_projection_joins_elided +|=
            qkv_execution.worker_joins_elided;
    }

    const attn = view(buffers.attn_out, &s_attn, width, dim);
    var attention_jobs: [width]AttentionLaneJob = undefined;
    var active_count: usize = 0;

    // Capacity validation for every live lane precedes RoPE or KV mutation.
    // Inactive lanes are represented only by a zero activation row; their KV
    // cache and all request-local state remain completely unobserved.
    for (0..width) |lane| {
        const attn_row = attn.asF32Unsafe()[lane * dim ..][0..dim];
        if (!active[lane]) {
            @memset(attn_row, 0);
            continue;
        }
        if (caches[lane].len() >= caches[lane].maxSeq())
            return generate_api.GenerateError.CacheFull;
    }

    // Complete every active lane's position-local RoPE and KV append before
    // exposing any attention job to the retained pool.
    for (0..width) |lane| {
        if (!active[lane]) continue;
        const position = caches[lane].len();
        const q_row = q_rows.asF32Unsafe()[lane * dim ..][0..dim];
        const k_row = k_rows.asF32Unsafe()[lane * kv_dim ..][0..kv_dim];
        const v_row = v_rows.asF32Unsafe()[lane * kv_dim ..][0..kv_dim];
        const attn_row = attn.asF32Unsafe()[lane * dim ..][0..dim];
        rope.apply(q_row, position, cfg.num_heads, cfg.head_dim);
        rope.apply(k_row, position, cfg.num_kv_heads, cfg.head_dim);
        const maybe_mark = if (kv_marks) |marks| marks[lane] else null;
        const appended_position = (if (maybe_mark) |runtime_mark| switch (runtime_mark) {
            .leased_paged16 => |txn| if (leased_coordinators) |coordinators|
                coordinators[lane].appendRowTxn(
                    txn,
                    layer_index,
                    k_row,
                    v_row,
                )
            else
                error.InvalidTransaction,
            else => caches[lane].appendRow(
                maybe_mark,
                layer_index,
                k_row,
                v_row,
            ),
        } else caches[lane].appendRow(
            null,
            layer_index,
            k_row,
            v_row,
        )) catch |err| switch (err) {
            error.CacheFull => return generate_api.GenerateError.CacheFull,
            else => return generate_api.GenerateError.ForwardFailed,
        };
        if (appended_position != position)
            return generate_api.GenerateError.ForwardFailed;
        var contiguous_k: []f32 = q_row[0..0];
        var contiguous_v: []f32 = q_row[0..0];
        var paged_prefix: ?paged_kv.LayerPrefix = null;
        switch (caches[lane]) {
            .contiguous => |*cache| {
                contiguous_k = cache.keysSliceCount(layer_index, position + 1);
                contiguous_v = cache.valuesSliceCount(layer_index, position + 1);
            },
            .paged16_required => |*cache| {
                const runtime_mark = maybe_mark orelse
                    return generate_api.GenerateError.ForwardFailed;
                const mark = switch (runtime_mark) {
                    .paged16_required => |value| value,
                    .leased_paged16 => |value| value.mark,
                    else => return generate_api.GenerateError.ForwardFailed,
                };
                paged_prefix = cache.txnPrefix(mark, layer_index) catch
                    return generate_api.GenerateError.ForwardFailed;
            },
        }
        attention_jobs[active_count] = .{
            .q = q_row,
            .k = contiguous_k,
            .v = contiguous_v,
            .out = attn_row,
            .dim = dim,
            .kv_dim = kv_dim,
            .kv_seq = position + 1,
            .num_heads = cfg.num_heads,
            .head_dim = cfg.head_dim,
            .rope_theta = cfg.rope_theta,
            .num_kv_heads = cfg.num_kv_heads,
            .mode = attention_mode,
            .paged_prefix = paged_prefix,
        };
        active_count += 1;
    }
    try runLaneAttention(pool, attention_jobs[0..active_count], telemetry);

    const projected = view(buffers.proj, &s_proj, width, dim);
    try projectBatch(pool, attn, weights.wo_int4.?, weights.bo, projected, dim, dim, buffers, tasks);
    const residual = view(buffers.h, &s_h, width, dim);
    addRows(residual.asF32Unsafe(), input.asF32Unsafe(), projected.asF32Unsafe());
    const mlp_norm = view(buffers.mlp_norm, &s_mlp, width, dim);
    kernels.rmsNormF32Rows4WeightStationary(
        residual,
        weights.post_attn_norm,
        cfg.rms_eps,
        mlp_norm,
    ) catch
        return generate_api.GenerateError.ForwardFailed;

    const pair = weights.w_gate_up_pair_int4.?;
    const down_weight = weights.w_down_int4.?;
    const down = view(buffers.down, &s_down, width, dim);
    switch (pair_down_mode) {
        .split_control => {
            int4_matmul.linearPairNibbleSiluQ8CompactBatchParallel(
                pool,
                mlp_norm.asF32Unsafe(),
                width,
                pair,
                &.{},
                &.{},
                buffers.q_scratch,
                buffers.scale_scratch,
                buffers.pair_q8,
                buffers.pair_scales,
                buffers.gate_tile,
                buffers.up_tile,
                down_weight.group_size,
                buffers.tile_rows,
                buffers.task_slots,
                tasks,
            ) catch return generate_api.GenerateError.ForwardFailed;
            int4_matmul.linearInt4WeightQ8PreparedBatchParallel(
                pool,
                buffers.pair_q8,
                buffers.pair_scales,
                down_weight,
                &.{},
                down,
                dim,
                hidden,
                tasks,
            ) catch return generate_api.GenerateError.ForwardFailed;
            if (telemetry) |out| {
                const down_worker_epoch: usize = @intFromBool(
                    int4_matmul.preparedBatchProjectionUsesWorkerEpoch(
                        dim,
                        tasks,
                    ),
                );
                out.pair_down_split_worker_epochs +|= 1 +
                    down_worker_epoch;
            }
        },
        .single_epoch_required => {
            const receipt = int4_matmul.linearPairNibbleSiluQ8CompactBatchDownWave(
                pool,
                mlp_norm.asF32Unsafe(),
                width,
                pair,
                &.{},
                &.{},
                buffers.q_scratch,
                buffers.scale_scratch,
                buffers.pair_q8,
                buffers.pair_scales,
                buffers.gate_tile,
                buffers.up_tile,
                .{
                    .weights = down_weight,
                    .bias = &.{},
                    .out = down,
                    .out_f = dim,
                    .in_f = hidden,
                },
                buffers.tile_rows,
                buffers.task_slots,
                tasks,
            ) catch |err| {
                if (err == error.OutOfMemory) {
                    if (telemetry) |out|
                        out.pair_down_enqueue_rejects +|= 1;
                    return generate_api.GenerateError.OutOfMemory;
                }
                return generate_api.GenerateError.ForwardFailed;
            };
            if (receipt.abi_version != pair_down_wave_abi)
                return generate_api.GenerateError.ForwardFailed;
            if (telemetry) |out| {
                out.pair_down_single_epochs +|= receipt.worker_epochs;
                out.pair_down_split_worker_epochs +|=
                    receipt.split_worker_epochs;
                out.pair_down_joins_elided +|=
                    receipt.worker_joins_elided;
                out.pair_down_worker_tasks +|= receipt.participants;
                out.pair_down_background_enqueues +|=
                    receipt.background_enqueues;
            }
        },
    }
    addRows(output.asF32Unsafe(), residual.asF32Unsafe(), down.asF32Unsafe());

    if (telemetry) |out| {
        out.layer_m4_graphs +|= 1;
        out.projection_m4_dispatches +|= 5;
        out.weight_stationary_norm_dispatches +|= 2;
        out.pair_m4_dispatches +|= 1;
    }
}

fn runTokenGraph(
    model: loader.LoadedModel,
    caches: *[width]RuntimeKvCache,
    kv_marks: ?*const [width]?RuntimeKvMark,
    leased_coordinators: ?*[width]leased_paged_kv.LeasedPagedKVCache,
    active: [width]bool,
    attention_mode: AttentionMode,
    pair_down_mode: PairDownMode,
    buffers: *prefill_buffers.Buffers,
    rope: *const RopeTable,
    pool: *std.Thread.Pool,
    tasks: usize,
    head_destination: HeadDestination,
    telemetry: ?*Telemetry,
) generate_api.GenerateError!void {
    const cfg = model.config;
    if (kv_marks) |marks| for (active, 0..) |is_active, lane| {
        if (is_active != (marks[lane] != null))
            return generate_api.GenerateError.ForwardFailed;
    };
    if (telemetry) |out| for (active) |is_active| {
        if (is_active)
            out.active_lane_steps +|= 1
        else
            out.padded_lane_steps +|= 1;
    };
    var current = buffers.x;
    var next = buffers.next;
    const layer_cfg: forward.LayerConfig = .{
        .dim = cfg.dim,
        .hidden_dim = cfg.hidden_dim,
        .rms_eps = cfg.rms_eps,
        .seq_len = 1,
        .num_heads = cfg.num_heads,
        .head_dim = cfg.head_dim,
        .rope_theta = cfg.rope_theta,
        .num_kv_heads = cfg.num_kv_heads,
    };
    for (model.layers, 0..) |weights, layer| {
        var in_shape: [2]usize = undefined;
        var out_shape: [2]usize = undefined;
        try forwardLayer(
            layer_cfg,
            weights,
            view(current, &in_shape, width, cfg.dim),
            view(next, &out_shape, width, cfg.dim),
            caches,
            kv_marks,
            leased_coordinators,
            layer,
            active,
            attention_mode,
            pair_down_mode,
            buffers,
            rope,
            pool,
            tasks,
            telemetry,
        );
        std.mem.swap([]f32, &current, &next);
    }
    if (kv_marks == null)
        for (active, 0..) |is_active, lane| if (is_active)
            caches[lane].commitLegacyGraph() catch
                return generate_api.GenerateError.ForwardFailed;

    const head_requested = switch (head_destination) {
        .none => false,
        .materialized, .streaming_required => true,
    };
    if (head_requested) {
        var hidden_shape: [2]usize = undefined;
        const final_hidden = view(buffers.h_norm, &hidden_shape, width, cfg.dim);
        var current_shape: [2]usize = undefined;
        kernels.rmsNormF32Rows4WeightStationary(
            view(current, &current_shape, width, cfg.dim),
            model.final_norm,
            cfg.rms_eps,
            final_hidden,
        ) catch return generate_api.GenerateError.ForwardFailed;
        switch (head_destination) {
            .none => unreachable,
            .materialized => |logit_rows| {
                try projectBatch(
                    pool,
                    final_hidden,
                    model.lm_head_int4.?,
                    &.{},
                    logit_rows,
                    cfg.vocab_size,
                    cfg.dim,
                    buffers,
                    tasks,
                );
                if (telemetry) |out|
                    out.materialized_lm_head_m4_dispatches +|= 1;
            },
            .streaming_required => |tokens| try runStreamingGreedyHead(
                pool,
                final_hidden,
                active,
                model.lm_head_int4.?,
                buffers.q_scratch,
                buffers.scale_scratch,
                tasks,
                tokens,
                telemetry,
            ),
        }
        if (telemetry) |out| {
            out.weight_stationary_norm_dispatches +|= 1;
            out.lm_head_m4_dispatches +|= 1;
        }
    }
    if (telemetry) |out| out.token_graphs +|= 1;
}

/// Generate exactly four independent requests through one strict M4 cohort.
/// Unsupported topology returns `DecodeLane4Unavailable`; it never runs M1.
pub fn generate(
    allocator: std.mem.Allocator,
    model: loader.LoadedModel,
    requests: [width]Request,
    options: Options,
) generate_api.GenerateError!Result {
    if (options.telemetry) |out| out.* = .{
        .greedy_head_abi_version = greedy_head_abi,
        .pair_down_wave_abi_version = pair_down_wave_abi,
        .greedy_head_mode = options.greedy_head_mode,
        .attention_mode = options.attention_mode,
        .pair_down_mode = options.pair_down_mode,
        .kv_cache_mode = options.kv_cache_mode,
        .paged_admission_mode = options.paged_admission_mode,
        .lease_reclaim_policy = options.lease_reclaim_policy,
        .kv_capacity_positions = options.kv_capacity_positions,
        .publication_mode = publicationMode(options),
        .token_txn_request_epoch = if (options.paged_lease_token_txn_publication) |publication|
            publication.request_epoch
        else if (options.paged_elastic_token_txn_publication) |publication|
            publication.request_epoch
        else if (options.paged_token_txn_publication) |publication|
            publication.request_epoch
        else if (options.token_txn_publication) |publication|
            publication.request_epoch
        else
            0,
    };
    if (options.resource_telemetry) |out| out.* = .{};
    const plan = preflight(model, requests, options) catch |err| {
        if (err == generate_api.GenerateError.LogitlessGreedyUnavailable and
            options.greedy_head_mode == .streaming_required)
        {
            if (options.telemetry) |out|
                out.streaming_greedy_head_rejects +|= 1;
        }
        return err;
    };
    const bank = options.request_resource_bank orelse
        return generate_api.GenerateError.ResourceAdmissionUnavailable;
    const owner_key = if (options.kv_cache_mode == .paged16_required)
        switch (options.paged_admission_mode) {
            .flat_capacity => pagedCohortOwnerKey(
                model,
                requests,
                plan.threads,
                options,
            ),
            .resident_child_required => pagedResidentCohortOwnerKey(
                model,
                requests,
                plan.threads,
                options,
            ),
            .lease_tree_required => pagedLeaseCohortOwnerKey(
                model,
                requests,
                plan.threads,
                options,
            ),
        }
    else blk: {
        const base = cohortOwnerKey(
            model,
            requests,
            plan.threads,
            options.greedy_head_mode,
            options.attention_mode,
            options.pair_down_mode,
            publicationMode(options),
        );
        break :blk if (options.kv_capacity_positions == 0)
            base
        else
            capacityBoundContiguousOwnerKey(
                base,
                options.kv_capacity_positions,
            );
    };
    if (options.resource_telemetry) |out|
        fillClaimTelemetry(out, plan.claim, owner_key);

    const reservation = bank.reserve(owner_key, plan.claim) catch |err| {
        recordBankTelemetry(
            options.resource_telemetry,
            bank,
            plan.claim,
            owner_key,
            null,
        );
        return mapBankError(err);
    };
    const committed_receipt = bank.commit(reservation) catch |err| {
        bank.cancel(reservation) catch {
            if (options.resource_telemetry) |out| out.release_failures +|= 1;
        };
        recordBankTelemetry(
            options.resource_telemetry,
            bank,
            plan.claim,
            owner_key,
            null,
        );
        return mapBankError(err);
    };
    // Install the sole release path immediately after commit. Observer
    // rejection therefore cannot leak a receipt, and the callback still runs
    // outside the Bank mutex before the pool or any request allocation.
    defer releaseReceipt(bank, committed_receipt, options.resource_telemetry);
    recordBankTelemetry(
        options.resource_telemetry,
        bank,
        plan.claim,
        owner_key,
        committed_receipt,
    );
    var shared_lease_tree: resource_bank.LeaseTreeV1 = undefined;
    var lease_scopes: [width]resource_bank.LeaseNodeV1 = undefined;
    var lease_tree_open = false;
    defer if (lease_tree_open) {
        bank.closeLeaseTree(shared_lease_tree) catch
            @panic("DecodeLane4 LeaseTree failed to close after reclamation");
        lease_tree_open = false;
    };
    if (options.paged_admission_mode == .lease_tree_required) {
        if (plan.paged_kv_bounded_payload_bytes == 0 or
            plan.paged_kv_required_lease_nodes < width or
            plan.claim.kv_bytes != plan.paged_kv_page_map_bytes or
            plan.claim.capsule_bytes != plan.paged_kv_binding_storage_bytes)
            return generate_api.GenerateError.ResourceAdmissionUnavailable;
        shared_lease_tree = bank.openLeaseTree(
            committed_receipt,
            pagedLeaseKey(owner_key, "tree", null),
            pagedLeaseKey(owner_key, "authority", null),
            .{ .kv_bytes = try toU64(plan.paged_kv_bounded_payload_bytes) },
        ) catch |err| return mapBankError(err);
        lease_tree_open = true;
        for (0..width) |lane| {
            const opened = bank.openScope(
                shared_lease_tree,
                pagedLeaseKey(owner_key, "scope", lane),
                pagedLeaseKey(owner_key, "tenant", lane),
                .{
                    .kv_bytes = try toU64(
                        plan.paged_kv_lane_bounded_payload_bytes[lane],
                    ),
                },
            ) catch |err| return mapBankError(err);
            shared_lease_tree = opened.tree;
            lease_scopes[lane] = opened.scope;
        }
    }
    var resident_child: ?resource_bank.ChildLease = null;
    if (options.paged_admission_mode == .resident_child_required) {
        if (plan.paged_kv_payload_ceiling_bytes == 0 or
            plan.claim.kv_bytes != plan.paged_kv_page_map_bytes)
            return generate_api.GenerateError.ResourceAdmissionUnavailable;
        resident_child = bank.openChild(
            committed_receipt,
            pagedResidentChildKey(owner_key, plan),
            .{ .kv_bytes = try toU64(plan.paged_kv_payload_ceiling_bytes) },
            .{},
        ) catch |err| {
            recordBankTelemetry(
                options.resource_telemetry,
                bank,
                plan.claim,
                owner_key,
                committed_receipt,
            );
            return mapBankError(err);
        };
        recordChildTelemetry(
            options.resource_telemetry,
            resident_child.?,
            plan.paged_kv_logical_capacity_bytes,
        );
        recordBankTelemetry(
            options.resource_telemetry,
            bank,
            plan.claim,
            owner_key,
            committed_receipt,
        );
    }
    defer closeResidentChildAssumeValid(
        bank,
        &resident_child,
        plan.paged_kv_logical_capacity_bytes,
        options.resource_telemetry,
    );
    var txn_session: token_txn.Session = .{};
    var paged_txn_session: paged_token_txn.Session = .{};
    var paged_elastic_txn_session: paged_elastic_token_txn.Session = .{};
    var paged_lease_txn_session: paged_lease_token_txn.Session = .{};
    var txn_session_live = false;
    var paged_txn_session_live = false;
    var paged_elastic_txn_session_live = false;
    var paged_lease_txn_session_live = false;
    defer if (paged_elastic_txn_session_live)
        paged_elastic_txn_session.close() catch
            @panic("DecodeLane4 PagedElasticTokenTxn session failed to close");
    defer if (paged_txn_session_live)
        paged_txn_session.close() catch
            @panic("DecodeLane4 PagedTokenTxn session failed to close");
    defer if (txn_session_live)
        txn_session.close() catch
            @panic("DecodeLane4 TokenTxn session failed to close");
    if (options.token_txn_publication) |publication| {
        txn_session.init(
            bank,
            committed_receipt,
            publication.request_epoch,
        ) catch return generate_api.GenerateError.TokenTransactionRejected;
        txn_session_live = true;
    }
    if (options.paged_token_txn_publication) |publication| {
        paged_txn_session.init(
            bank,
            committed_receipt,
            publication.request_epoch,
            paged_decode_abi,
            plan.claim.kv_bytes,
        ) catch return generate_api.GenerateError.TokenTransactionRejected;
        paged_txn_session_live = true;
    }
    if (options.paged_elastic_token_txn_publication) |publication| {
        paged_elastic_txn_session.init(
            bank,
            committed_receipt,
            resident_child orelse
                return generate_api.GenerateError.ResourceAdmissionUnavailable,
            publication.request_epoch,
            paged_resident_decode_abi,
            try toU64(plan.paged_kv_logical_capacity_bytes),
        ) catch return generate_api.GenerateError.TokenTransactionRejected;
        paged_elastic_txn_session_live = true;
    }
    // Bind the publication fence before invoking arbitrary receipt evidence.
    // A callback may inspect this committed receipt but cannot steal its sole
    // TokenTxn session or leave release pinned behind an unknown coordinator.
    if (options.resource_commit_observer) |observer|
        try generate_api.runResourceCommitObserver(observer, committed_receipt);

    var pool: std.Thread.Pool = undefined;
    pool.init(.{
        .allocator = std.heap.c_allocator,
        .n_jobs = plan.threads - 1,
    }) catch return generate_api.GenerateError.OutOfMemory;
    defer pool.deinit();

    var buffers = prefill_buffers.Buffers.initWithSpec(
        allocator,
        plan.frame_spec,
    ) catch return generate_api.GenerateError.OutOfMemory;
    defer buffers.deinit();

    var caches: [width]RuntimeKvCache = undefined;
    var initialized_caches: usize = 0;
    defer for (caches[0..initialized_caches]) |*cache| cache.deinit();
    for (0..width) |lane| {
        caches[lane] = RuntimeKvCache.init(
            allocator,
            options.kv_cache_mode,
            model.config.num_layers,
            model.config.num_kv_heads * model.config.head_dim,
            plan.lane_contexts[lane],
        ) catch return generate_api.GenerateError.OutOfMemory;
        initialized_caches += 1;
    }
    var lease_bindings: [width][]leased_paged_kv.PageLeaseBindingV1 = undefined;
    var initialized_lease_bindings: usize = 0;
    defer for (lease_bindings[0..initialized_lease_bindings]) |bindings|
        allocator.free(bindings);
    // The v3 session validates each coordinator and its cache while closing.
    // Declare this after cache/binding cleanup so reverse defer order is:
    // reclaim pages, close the session, free bindings, then deinit caches.
    defer if (paged_lease_txn_session_live)
        paged_lease_txn_session.close() catch
            @panic("DecodeLane4 PagedLeaseTokenTxn session failed to close");
    var leased_coordinators =
        [_]leased_paged_kv.LeasedPagedKVCache{.{}} ** width;
    var initialized_leased_coordinators: usize = 0;
    defer if (initialized_leased_coordinators != 0) {
        if (paged_lease_txn_session_live) {
            paged_lease_txn_session.reclaimAllForTeardown() catch
                @panic("DecodeLane4 leased pages failed teardown reclamation");
        } else {
            for (leased_coordinators[0..initialized_leased_coordinators]) |*coordinator|
                coordinator.reclaimForTeardown(0) catch
                    @panic("DecodeLane4 unbound leased cache failed teardown");
        }
    };
    if (options.paged_lease_token_txn_publication) |publication| {
        if (!lease_tree_open)
            return generate_api.GenerateError.ResourceAdmissionUnavailable;
        for (0..width) |lane| {
            const cache = caches[lane].pagedPtr() orelse
                return generate_api.GenerateError.TokenTransactionRejected;
            const page_count = cache.capacityLedger().page_count_capacity;
            lease_bindings[lane] = allocator.alloc(
                leased_paged_kv.PageLeaseBindingV1,
                page_count,
            ) catch return generate_api.GenerateError.OutOfMemory;
            initialized_lease_bindings += 1;
            leased_coordinators[lane].init(
                bank,
                &shared_lease_tree,
                lease_scopes[lane],
                cache,
                lease_bindings[lane],
                publication.request_epoch,
                @intFromPtr(&paged_lease_txn_session),
                &paged_lease_txn_session.next_sequence,
            ) catch return generate_api.GenerateError.TokenTransactionRejected;
            initialized_leased_coordinators += 1;
        }
        const coordinator_ptrs: [width]*leased_paged_kv.LeasedPagedKVCache = .{
            &leased_coordinators[0],
            &leased_coordinators[1],
            &leased_coordinators[2],
            &leased_coordinators[3],
        };
        paged_lease_txn_session.init(
            bank,
            committed_receipt,
            &shared_lease_tree,
            coordinator_ptrs,
            publication.request_epoch,
            paged_lease_decode_abi,
        ) catch return generate_api.GenerateError.TokenTransactionRejected;
        paged_lease_txn_session_live = true;
    }
    var result: Result = .{
        .allocator = allocator,
        .storage = undefined,
        .lengths = [_]usize{0} ** width,
    };
    var initialized_outputs: usize = 0;
    errdefer for (result.storage[0..initialized_outputs]) |journal|
        allocator.free(journal);
    for (requests, 0..) |request, lane| {
        result.storage[lane] = allocator.alloc(
            u32,
            request.max_new_tokens,
        ) catch return generate_api.GenerateError.OutOfMemory;
        initialized_outputs += 1;
    }

    var logits: ?tensor.Tensor = switch (options.greedy_head_mode) {
        .materialized => tensor.zerosF32(
            allocator,
            &.{ width, model.config.vocab_size },
        ) catch return generate_api.GenerateError.OutOfMemory,
        .streaming_required => null,
    };
    defer if (logits) |*value| value.deinit();
    const needs_sample_scratch = for (requests) |request| {
        if (request.forced_tokens.len == 0 and request.sampler.temperature != 0)
            break true;
    } else false;
    const sample_scratch = allocator.alloc(
        sampling.Candidate,
        if (needs_sample_scratch) model.config.vocab_size else 0,
    ) catch return generate_api.GenerateError.OutOfMemory;
    defer allocator.free(sample_scratch);

    var rope = RopeTable.init(
        allocator,
        plan.max_context,
        model.config.head_dim,
        model.config.rope_theta,
    ) catch return generate_api.GenerateError.OutOfMemory;
    defer rope.deinit();

    // Keep the Bank publication fence bound until all later-declared cache and
    // allocator-owner defers have run. An adversarial sink may retain copied
    // handles, but it cannot close the child or release the parent while any
    // charged KV payload still exists. Session.close does not dereference the
    // cache/output bindings, so closing after their teardown is deliberate.

    if (options.telemetry) |out| {
        out.admitted_cohorts = 1;
        out.thread_participants = plan.threads;
        out.frame_payload_bytes = buffers.tensorStorageBytes();
        out.paged_kv_logical_capacity_bytes =
            plan.paged_kv_logical_capacity_bytes;
        out.paged_kv_page_map_commitment_bytes =
            plan.paged_kv_page_map_bytes;
        out.paged_kv_payload_ceiling_bytes =
            plan.paged_kv_payload_ceiling_bytes;
        out.paged_lease_binding_storage_bytes =
            plan.paged_kv_binding_storage_bytes;
        out.paged_lease_required_roots =
            @intFromBool(options.paged_admission_mode == .lease_tree_required);
        out.paged_lease_required_nodes = if (options.paged_admission_mode == .lease_tree_required) plan.paged_kv_required_lease_nodes else 0;
        if (options.greedy_head_mode == .streaming_required)
            out.materialized_logits_reclaimed_bytes =
                plan.materialized_logits_bytes;
    }

    const all_active = [_]bool{true} ** width;
    var streamed_tokens = [_]u32{0} ** width;
    const prompt_len = requests[0].prompt.len;
    for (0..prompt_len) |position| {
        for (requests, 0..) |request, lane| {
            const row = buffers.x[lane * model.config.dim ..][0..model.config.dim];
            try loadEmbeddingRow(model, request.prompt[position], row);
        }
        var prompt_marks = if (options.kv_cache_mode == .paged16_required)
            switch (options.paged_admission_mode) {
                .resident_child_required => try beginResidentKvMarks(
                    &caches,
                    all_active,
                    &paged_elastic_txn_session,
                    &resident_child,
                    options.resource_telemetry,
                    options.telemetry,
                ),
                .lease_tree_required => try beginLeasedKvMarks(
                    bank,
                    &leased_coordinators,
                    all_active,
                    options.paged_lease_token_txn_publication.?.request_epoch,
                    options.paged_lease_admission_observer,
                    options.telemetry,
                ),
                .flat_capacity => try beginKvMarks(
                    &caches,
                    all_active,
                    options.telemetry,
                ),
            }
        else
            [_]?RuntimeKvMark{null} ** width;
        runTokenGraph(
            model,
            &caches,
            if (options.kv_cache_mode == .paged16_required)
                &prompt_marks
            else
                null,
            if (options.paged_admission_mode == .lease_tree_required)
                &leased_coordinators
            else
                null,
            all_active,
            options.attention_mode,
            options.pair_down_mode,
            &buffers,
            &rope,
            &pool,
            plan.threads,
            if (position + 1 != prompt_len)
                .none
            else switch (options.greedy_head_mode) {
                .materialized => .{ .materialized = logits.? },
                .streaming_required => .{
                    .streaming_required = &streamed_tokens,
                },
            },
            options.telemetry,
        ) catch |err| {
            if (options.kv_cache_mode == .paged16_required) {
                recordTokenTxnProvisionalAbort(options.telemetry);
                const clean = if (options.paged_admission_mode == .lease_tree_required) abortLeasedKvMarks(
                    &leased_coordinators,
                    &prompt_marks,
                ) else abortKvMarks(&caches, &prompt_marks);
                if (!clean)
                    return generate_api.GenerateError.TokenTransactionRejected;
            }
            return err;
        };
        if (options.kv_cache_mode == .paged16_required) {
            if (options.paged_admission_mode == .lease_tree_required)
                try commitLeasedPromptMarks(
                    &leased_coordinators,
                    &prompt_marks,
                )
            else
                try commitPagedPromptMarks(&caches, &prompt_marks);
        }
    }

    var prngs: [width]std.Random.DefaultPrng = undefined;
    var sampling_calls = [_]usize{0} ** width;
    var active = [_]bool{true} ** width;
    var strict_terminal_states_published = options.telemetry == null;
    for (requests, 0..) |request, lane| {
        prngs[lane] = std.Random.DefaultPrng.init(request.seed);
    }

    if (options.paged_token_txn_publication != null or
        options.paged_elastic_token_txn_publication != null or
        options.paged_lease_token_txn_publication != null)
    {
        var first_staged = [_]?StagedToken{null} ** width;
        for (requests, 0..) |request, lane| {
            first_staged[lane] = stageToken(
                model,
                request,
                lane,
                0,
                options.greedy_head_mode,
                logits,
                &streamed_tokens,
                prngs[lane],
                sampling_calls[lane],
                sample_scratch,
            ) catch |err| {
                recordTokenTxnProvisionalAbort(options.telemetry);
                return err;
            };
        }
        const terminal_wave = tokenWaveTerminatesSession(
            active,
            &first_staged,
        );
        var prepared_terminal_states =
            [_]generate_api.GenerationStateTelemetry{.{}} ** width;
        var no_marks = [_]?RuntimeKvMark{null} ** width;
        var lease_hash_tasks: usize = 0;
        if (options.paged_lease_token_txn_publication != null and
            options.telemetry != null)
        {
            lease_hash_tasks = prepareLeasedRetiringLaneStatesParallel(
                &pool,
                requests,
                &caches,
                &no_marks,
                &result,
                active,
                &first_staged,
                &prepared_terminal_states,
            ) catch |err| {
                if (err == generate_api.GenerateError.OutOfMemory) {
                    if (options.telemetry) |out|
                        out.state_hash_enqueue_rejects +|= 1;
                }
                recordTokenTxnProvisionalAbort(options.telemetry);
                return err;
            };
        } else if (terminal_wave and options.telemetry != null)
            preparePagedTerminalLaneStatesParallel(
                &pool,
                requests,
                &caches,
                &no_marks,
                &result,
                active,
                &first_staged,
                sampling_calls,
                &prngs,
                &prepared_terminal_states,
            ) catch |err| {
                if (err == generate_api.GenerateError.OutOfMemory) {
                    if (options.telemetry) |out|
                        out.state_hash_enqueue_rejects +|= 1;
                }
                recordTokenTxnProvisionalAbort(options.telemetry);
                return err;
            };
        if (options.paged_lease_token_txn_publication) |publication| {
            const receipt = try commitPagedLeaseTokenWave(
                &paged_lease_txn_session,
                publication,
                requests,
                &leased_coordinators,
                &no_marks,
                &first_staged,
                &prngs,
                &sampling_calls,
                &result,
                &active,
                options.telemetry,
            );
            publishLeasedRetiringLaneStates(
                options.telemetry,
                prepared_terminal_states,
                lease_hash_tasks,
            );
            const reclaimed_mask = try reclaimPublishedLeaseTerminals(
                &paged_lease_txn_session,
                receipt,
                options.lease_reclaim_policy,
                options.telemetry,
            );
            observePagedLeaseWave(
                options.paged_lease_wave_observer,
                bank,
                shared_lease_tree,
                &receipt,
                active,
                options.lease_reclaim_policy,
                reclaimed_mask,
            ) catch |err| return mapPagedLeaseRuntimeError(
                &paged_lease_txn_session,
                err,
            );
        } else if (options.paged_elastic_token_txn_publication) |publication|
            try commitPagedElasticTokenWave(
                &paged_elastic_txn_session,
                publication,
                requests,
                &caches,
                &no_marks,
                &first_staged,
                &prngs,
                &sampling_calls,
                &result,
                &active,
                options.telemetry,
            )
        else
            try commitPagedTokenWave(
                &paged_txn_session,
                options.paged_token_txn_publication.?,
                requests,
                &caches,
                &no_marks,
                &first_staged,
                &prngs,
                &sampling_calls,
                &result,
                &active,
                options.telemetry,
            );
        if (terminal_wave and
            options.paged_lease_token_txn_publication == null)
        {
            publishPreparedTerminalLaneStates(
                options.telemetry,
                prepared_terminal_states,
            );
            strict_terminal_states_published = true;
        } else if (terminal_wave) {
            strict_terminal_states_published = true;
        }
    } else if (options.token_txn_publication) |publication| {
        var first_staged = [_]?StagedToken{null} ** width;
        for (requests, 0..) |request, lane| {
            first_staged[lane] = stageToken(
                model,
                request,
                lane,
                0,
                options.greedy_head_mode,
                logits,
                &streamed_tokens,
                prngs[lane],
                sampling_calls[lane],
                sample_scratch,
            ) catch |err| {
                recordTokenTxnProvisionalAbort(options.telemetry);
                return err;
            };
        }
        const terminal_wave = tokenWaveTerminatesSession(
            active,
            &first_staged,
        );
        var prepared_terminal_states =
            [_]generate_api.GenerationStateTelemetry{.{}} ** width;
        if (terminal_wave and options.telemetry != null)
            prepareRuntimeContiguousTerminalLaneStatesParallel(
                &pool,
                requests,
                &caches,
                &result,
                active,
                &first_staged,
                sampling_calls,
                &prngs,
                &prepared_terminal_states,
            ) catch |err| {
                if (err == generate_api.GenerateError.OutOfMemory) {
                    if (options.telemetry) |out|
                        out.state_hash_enqueue_rejects +|= 1;
                }
                recordTokenTxnProvisionalAbort(options.telemetry);
                return err;
            };
        var no_marks = [_]?RuntimeKvMark{null} ** width;
        try commitTokenWave(
            &txn_session,
            publication,
            requests,
            &caches,
            &no_marks,
            &first_staged,
            &prngs,
            &sampling_calls,
            &result,
            &active,
            options.telemetry,
        );
        if (terminal_wave) {
            publishPreparedTerminalLaneStates(
                options.telemetry,
                prepared_terminal_states,
            );
            strict_terminal_states_published = true;
        }
    } else {
        // Preserve the v3 observer boundary: select and publish one lane at a
        // time so lane 0 TTFT and early observer rejection do not wait for
        // three unrelated full-vocabulary decisions.
        for (requests, 0..) |request, lane| {
            const token = try stageToken(
                model,
                request,
                lane,
                0,
                options.greedy_head_mode,
                logits,
                &streamed_tokens,
                prngs[lane],
                sampling_calls[lane],
                sample_scratch,
            );
            prngs[lane].s = token.rng_after;
            sampling_calls[lane] = token.sampling_calls_after;
            result.storage[lane][0] = token.token_id;
            result.lengths[lane] = 1;
            try publishToken(
                options.token_publication_observer,
                lane,
                0,
                token.token_id,
                token.terminal,
            );
            active[lane] = !token.terminal;
        }
    }

    while (true) {
        var have_active = false;
        for (active) |is_active| have_active = have_active or is_active;
        if (!have_active) break;

        for (active, 0..) |is_active, lane| {
            const row = buffers.x[lane * model.config.dim ..][0..model.config.dim];
            if (is_active) {
                const prior = result.storage[lane][result.lengths[lane] - 1];
                loadEmbeddingRow(model, prior, row) catch |err|
                    return mapPagedLeaseRuntimeError(
                        &paged_lease_txn_session,
                        err,
                    );
            } else {
                @memset(row, 0);
            }
        }
        const strict_publication = options.token_txn_publication != null or
            options.paged_token_txn_publication != null or
            options.paged_elastic_token_txn_publication != null or
            options.paged_lease_token_txn_publication != null;
        var marks = if (strict_publication)
            switch (options.paged_admission_mode) {
                .resident_child_required => beginResidentKvMarks(
                    &caches,
                    active,
                    &paged_elastic_txn_session,
                    &resident_child,
                    options.resource_telemetry,
                    options.telemetry,
                ) catch |err| return mapPagedLeaseRuntimeError(
                    &paged_lease_txn_session,
                    err,
                ),
                .lease_tree_required => beginLeasedKvMarks(
                    bank,
                    &leased_coordinators,
                    active,
                    options.paged_lease_token_txn_publication.?.request_epoch,
                    options.paged_lease_admission_observer,
                    options.telemetry,
                ) catch |err| return mapPagedLeaseRuntimeError(
                    &paged_lease_txn_session,
                    err,
                ),
                .flat_capacity => beginKvMarks(
                    &caches,
                    active,
                    options.telemetry,
                ) catch |err| return mapPagedLeaseRuntimeError(
                    &paged_lease_txn_session,
                    err,
                ),
            }
        else
            [_]?RuntimeKvMark{null} ** width;
        runTokenGraph(
            model,
            &caches,
            if (strict_publication) &marks else null,
            if (options.paged_admission_mode == .lease_tree_required)
                &leased_coordinators
            else
                null,
            active,
            options.attention_mode,
            options.pair_down_mode,
            &buffers,
            &rope,
            &pool,
            plan.threads,
            switch (options.greedy_head_mode) {
                .materialized => .{ .materialized = logits.? },
                .streaming_required => .{
                    .streaming_required = &streamed_tokens,
                },
            },
            options.telemetry,
        ) catch |err| {
            if (strict_publication) {
                recordTokenTxnProvisionalAbort(options.telemetry);
                const clean = if (options.paged_admission_mode == .lease_tree_required) abortLeasedKvMarks(
                    &leased_coordinators,
                    &marks,
                ) else abortKvMarks(&caches, &marks);
                if (!clean)
                    return mapPagedLeaseRuntimeError(
                        &paged_lease_txn_session,
                        generate_api.GenerateError.TokenTransactionRejected,
                    );
            }
            return mapPagedLeaseRuntimeError(
                &paged_lease_txn_session,
                err,
            );
        };

        if (strict_publication) {
            var staged = [_]?StagedToken{null} ** width;
            for (requests, 0..) |request, lane| {
                if (!active[lane]) continue;
                const index = result.lengths[lane];
                staged[lane] = stageToken(
                    model,
                    request,
                    lane,
                    index,
                    options.greedy_head_mode,
                    logits,
                    &streamed_tokens,
                    prngs[lane],
                    sampling_calls[lane],
                    sample_scratch,
                ) catch |err| {
                    recordTokenTxnProvisionalAbort(options.telemetry);
                    const clean = if (options.paged_admission_mode == .lease_tree_required) abortLeasedKvMarks(
                        &leased_coordinators,
                        &marks,
                    ) else abortKvMarks(&caches, &marks);
                    if (!clean)
                        return mapPagedLeaseRuntimeError(
                            &paged_lease_txn_session,
                            generate_api.GenerateError.TokenTransactionRejected,
                        );
                    return mapPagedLeaseRuntimeError(
                        &paged_lease_txn_session,
                        err,
                    );
                };
            }
            const terminal_wave = tokenWaveTerminatesSession(active, &staged);
            var prepared_terminal_states =
                [_]generate_api.GenerationStateTelemetry{.{}} ** width;
            var lease_hash_tasks: usize = 0;
            if (options.paged_lease_token_txn_publication != null and
                options.telemetry != null)
            {
                lease_hash_tasks = prepareLeasedRetiringLaneStatesParallel(
                    &pool,
                    requests,
                    &caches,
                    &marks,
                    &result,
                    active,
                    &staged,
                    &prepared_terminal_states,
                ) catch |err| {
                    if (err == generate_api.GenerateError.OutOfMemory) {
                        if (options.telemetry) |out|
                            out.state_hash_enqueue_rejects +|= 1;
                    }
                    recordTokenTxnProvisionalAbort(options.telemetry);
                    if (!abortLeasedKvMarks(&leased_coordinators, &marks))
                        return mapPagedLeaseRuntimeError(
                            &paged_lease_txn_session,
                            generate_api.GenerateError.TokenTransactionRejected,
                        );
                    return mapPagedLeaseRuntimeError(
                        &paged_lease_txn_session,
                        err,
                    );
                };
            } else if (terminal_wave and options.telemetry != null) {
                const hash_result = if (options.kv_cache_mode == .paged16_required)
                    preparePagedTerminalLaneStatesParallel(
                        &pool,
                        requests,
                        &caches,
                        &marks,
                        &result,
                        active,
                        &staged,
                        sampling_calls,
                        &prngs,
                        &prepared_terminal_states,
                    )
                else
                    prepareRuntimeContiguousTerminalLaneStatesParallel(
                        &pool,
                        requests,
                        &caches,
                        &result,
                        active,
                        &staged,
                        sampling_calls,
                        &prngs,
                        &prepared_terminal_states,
                    );
                hash_result catch |err| {
                    if (err == generate_api.GenerateError.OutOfMemory) {
                        if (options.telemetry) |out|
                            out.state_hash_enqueue_rejects +|= 1;
                    }
                    recordTokenTxnProvisionalAbort(options.telemetry);
                    const clean = if (options.paged_admission_mode == .lease_tree_required) abortLeasedKvMarks(
                        &leased_coordinators,
                        &marks,
                    ) else abortKvMarks(&caches, &marks);
                    if (!clean)
                        return mapPagedLeaseRuntimeError(
                            &paged_lease_txn_session,
                            generate_api.GenerateError.TokenTransactionRejected,
                        );
                    return mapPagedLeaseRuntimeError(
                        &paged_lease_txn_session,
                        err,
                    );
                };
            }
            if (options.paged_lease_token_txn_publication) |publication| {
                const receipt = commitPagedLeaseTokenWave(
                    &paged_lease_txn_session,
                    publication,
                    requests,
                    &leased_coordinators,
                    &marks,
                    &staged,
                    &prngs,
                    &sampling_calls,
                    &result,
                    &active,
                    options.telemetry,
                ) catch |err| return mapPagedLeaseRuntimeError(
                    &paged_lease_txn_session,
                    err,
                );
                publishLeasedRetiringLaneStates(
                    options.telemetry,
                    prepared_terminal_states,
                    lease_hash_tasks,
                );
                const reclaimed_mask = reclaimPublishedLeaseTerminals(
                    &paged_lease_txn_session,
                    receipt,
                    options.lease_reclaim_policy,
                    options.telemetry,
                ) catch |err| return mapPagedLeaseRuntimeError(
                    &paged_lease_txn_session,
                    err,
                );
                observePagedLeaseWave(
                    options.paged_lease_wave_observer,
                    bank,
                    shared_lease_tree,
                    &receipt,
                    active,
                    options.lease_reclaim_policy,
                    reclaimed_mask,
                ) catch |err| return mapPagedLeaseRuntimeError(
                    &paged_lease_txn_session,
                    err,
                );
            } else if (options.paged_elastic_token_txn_publication) |publication| {
                try commitPagedElasticTokenWave(
                    &paged_elastic_txn_session,
                    publication,
                    requests,
                    &caches,
                    &marks,
                    &staged,
                    &prngs,
                    &sampling_calls,
                    &result,
                    &active,
                    options.telemetry,
                );
            } else if (options.paged_token_txn_publication) |publication| {
                try commitPagedTokenWave(
                    &paged_txn_session,
                    publication,
                    requests,
                    &caches,
                    &marks,
                    &staged,
                    &prngs,
                    &sampling_calls,
                    &result,
                    &active,
                    options.telemetry,
                );
            } else if (options.token_txn_publication) |publication| {
                try commitTokenWave(
                    &txn_session,
                    publication,
                    requests,
                    &caches,
                    &marks,
                    &staged,
                    &prngs,
                    &sampling_calls,
                    &result,
                    &active,
                    options.telemetry,
                );
            } else unreachable;
            if (terminal_wave and
                options.paged_lease_token_txn_publication == null)
            {
                publishPreparedTerminalLaneStates(
                    options.telemetry,
                    prepared_terminal_states,
                );
                strict_terminal_states_published = true;
            } else if (terminal_wave) {
                strict_terminal_states_published = true;
            }
        } else {
            for (requests, 0..) |request, lane| {
                if (!active[lane]) continue;
                const index = result.lengths[lane];
                const token = try stageToken(
                    model,
                    request,
                    lane,
                    index,
                    options.greedy_head_mode,
                    logits,
                    &streamed_tokens,
                    prngs[lane],
                    sampling_calls[lane],
                    sample_scratch,
                );
                prngs[lane].s = token.rng_after;
                sampling_calls[lane] = token.sampling_calls_after;
                result.storage[lane][index] = token.token_id;
                result.lengths[lane] += 1;
                try publishToken(
                    options.token_publication_observer,
                    lane,
                    index,
                    token.token_id,
                    token.terminal,
                );
                active[lane] = !token.terminal;
            }
        }
    }

    const any_strict_publication = options.token_txn_publication != null or
        options.paged_token_txn_publication != null or
        options.paged_elastic_token_txn_publication != null or
        options.paged_lease_token_txn_publication != null;
    if (!any_strict_publication) {
        try recordRuntimeContiguousStatesParallel(
            &pool,
            &caches,
            &result,
            sampling_calls,
            &prngs,
            options.telemetry,
        );
    } else if (!strict_terminal_states_published) {
        if (paged_lease_txn_session.next_sequence != 0)
            return generate_api.GenerateError.PostPublicationGenerationInterrupted;
        @panic("DecodeLane4 terminal TokenTxn state evidence was not prepared");
    }
    if (options.kv_cache_mode == .paged16_required) {
        if (options.paged_admission_mode == .lease_tree_required and
            options.lease_reclaim_policy == .terminal_immediate)
        {
            if (options.telemetry) |out| {
                out.paged_kv_capacity_bytes =
                    plan.paged_kv_logical_capacity_bytes;
                out.paged_kv_resident_bytes = plan.paged_kv_page_map_bytes;
                out.paged_kv_committed_payload_bytes = 0;
                for (&caches) |*runtime_cache| {
                    const cache = runtime_cache.pagedPtr() orelse
                        return mapPagedLeaseRuntimeError(
                            &paged_lease_txn_session,
                            generate_api.GenerateError.ForwardFailed,
                        );
                    out.paged_kv_capacity_pages +|=
                        cache.capacityLedger().page_count_capacity;
                }
                if (!shared_lease_tree.current.isZero() or
                    out.paged_lease_reclaimed_lanes != width or
                    out.paged_lease_retained_payload_bytes != 0)
                    return generate_api.GenerateError.PostPublicationReclaimPending;
            }
        } else {
            recordPagedKvTelemetry(&caches, options.telemetry) catch |err|
                return mapPagedLeaseRuntimeError(
                    &paged_lease_txn_session,
                    err,
                );
        }
        if (options.telemetry) |out| {
            const capacity = std.math.cast(
                u64,
                out.paged_kv_capacity_bytes,
            ) orelse return mapPagedLeaseRuntimeError(
                &paged_lease_txn_session,
                generate_api.GenerateError.ForwardFailed,
            );
            if (capacity != plan.paged_kv_logical_capacity_bytes or
                out.paged_kv_resident_bytes >
                    out.paged_kv_capacity_bytes)
                return mapPagedLeaseRuntimeError(
                    &paged_lease_txn_session,
                    generate_api.GenerateError.TokenTransactionRejected,
                );
            if (options.paged_admission_mode == .resident_child_required) {
                const lease = resident_child orelse
                    return generate_api.GenerateError.TokenTransactionRejected;
                const payload_commitment = out.paged_kv_resident_bytes -|
                    out.paged_kv_page_map_commitment_bytes;
                if (payload_commitment != lease.claim.kv_bytes or
                    !std.meta.eql(lease, paged_elastic_txn_session.child_lease))
                    return generate_api.GenerateError.TokenTransactionRejected;
                out.paged_kv_child_current_bytes = payload_commitment;
                recordChildTelemetry(
                    options.resource_telemetry,
                    lease,
                    plan.paged_kv_logical_capacity_bytes,
                );
                recordBankTelemetry(
                    options.resource_telemetry,
                    bank,
                    plan.claim,
                    owner_key,
                    committed_receipt,
                );
            } else if (options.paged_admission_mode == .lease_tree_required) {
                const payload_commitment = out.paged_kv_resident_bytes -|
                    out.paged_kv_page_map_commitment_bytes;
                if (payload_commitment != shared_lease_tree.current.kv_bytes or
                    payload_commitment !=
                        out.paged_lease_retained_payload_bytes)
                    return mapPagedLeaseRuntimeError(
                        &paged_lease_txn_session,
                        generate_api.GenerateError.TokenTransactionRejected,
                    );
                recordBankTelemetry(
                    options.resource_telemetry,
                    bank,
                    plan.claim,
                    owner_key,
                    committed_receipt,
                );
            }
        }
    }
    return result;
}

fn testRows4Weight(
    allocator: std.mem.Allocator,
    out_f: usize,
    in_f: usize,
) !int4_weights.Int4WeightData {
    const group_size: u32 = 8;
    const elements = try std.math.mul(usize, out_f, in_f);
    const packed_bytes = try allocator.alloc(u8, elements / 2);
    @memset(packed_bytes, 0x77); // exact zero coefficients
    const scales = try allocator.alloc(f32, elements / group_size);
    @memset(scales, 1.0);
    var weights: int4_weights.Int4WeightData = .{
        .packed_bytes = packed_bytes,
        .scales = scales,
        .group_size = group_size,
        .num_elements = elements,
    };
    weights = try int4_weights.withRows4F16Scales(
        allocator,
        weights,
        out_f,
    );
    return int4_weights.withRows4K16Packing(allocator, weights, out_f);
}

fn testWriteNibble(bytes: []u8, index: usize, value: u8) void {
    const byte_index = index / 2;
    if (index & 1 == 0) {
        bytes[byte_index] = (bytes[byte_index] & 0xf0) | (value & 0x0f);
    } else {
        bytes[byte_index] = (bytes[byte_index] & 0x0f) | ((value & 0x0f) << 4);
    }
}

fn testPatternRows4Weight(
    allocator: std.mem.Allocator,
    out_f: usize,
    in_f: usize,
    group_size: u32,
) !int4_weights.Int4WeightData {
    const group: usize = group_size;
    if (group == 0 or in_f % group != 0) return error.InvalidShape;
    const elements = try std.math.mul(usize, out_f, in_f);
    const packed_bytes = try allocator.alloc(u8, elements / 2);
    @memset(packed_bytes, 0);
    for (0..out_f) |row| {
        for (0..in_f) |col| {
            // Exercise every signed INT4 coefficient and deliberately mix
            // row, K-block, and rows4-lane offsets.
            const code: u8 = @intCast(
                (row * 11 + col * 7 + (row / 4) * 3) % 16,
            );
            testWriteNibble(packed_bytes, row * in_f + col, code);
        }
    }
    const scales = try allocator.alloc(f32, elements / group);
    const groups_per_row = in_f / group;
    for (0..out_f) |row| {
        for (0..groups_per_row) |k_group| {
            // Binary fractions survive the required f32 -> f16 rows4 mirror
            // exactly while remaining non-uniform across both dimensions.
            const numerator = 4 + (row * 5 + k_group * 7) % 29;
            scales[row * groups_per_row + k_group] =
                @as(f32, @floatFromInt(numerator)) / 16.0;
        }
    }
    var weights: int4_weights.Int4WeightData = .{
        .packed_bytes = packed_bytes,
        .scales = scales,
        .group_size = group_size,
        .num_elements = elements,
    };
    weights = try int4_weights.withRows4F16Scales(
        allocator,
        weights,
        out_f,
    );
    return int4_weights.withRows4K16Packing(allocator, weights, out_f);
}

fn testPreparedModel(vocab_size: usize) !loader.LoadedModel {
    return testPreparedModelLayers(vocab_size, 1);
}

fn testPreparedModelLayers(
    vocab_size: usize,
    num_layers: usize,
) !loader.LoadedModel {
    const allocator = std.testing.allocator;
    const dim: usize = 16;
    const hidden: usize = 32;
    if (vocab_size == 0 or vocab_size % 4 != 0 or num_layers == 0)
        return error.InvalidShape;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const common = try testRows4Weight(a, dim, dim);
    const vocabulary = try testRows4Weight(a, vocab_size, dim);
    const gate = try testRows4Weight(a, hidden, dim);
    const up = try testRows4Weight(a, hidden, dim);
    const down = try testRows4Weight(a, dim, hidden);
    const paired_bytes = try a.alloc(u8, hidden * dim);
    const paired_scales = try a.alloc(
        f16,
        2 * hidden * dim / gate.group_size,
    );
    const pair = try int4_weights.pairRows4K16(
        gate,
        up,
        hidden,
        paired_bytes,
        paired_scales,
    );
    const layer_norm = try a.alloc(f32, dim);
    @memset(layer_norm, 1.0);
    const final_norm = try a.alloc(f32, dim);
    @memset(final_norm, 1.0);

    const layers = try allocator.alloc(forward.LayerWeights, num_layers);
    errdefer allocator.free(layers);
    const layer: forward.LayerWeights = .{
        .input_norm = layer_norm,
        .wq = &.{},
        .wk = &.{},
        .wv = &.{},
        .wo = &.{},
        .bq = &.{},
        .bk = &.{},
        .bv = &.{},
        .bo = &.{},
        .post_attn_norm = layer_norm,
        .w_gate = &.{},
        .w_up = &.{},
        .w_down = &.{},
        .wq_int4 = common,
        .wk_int4 = common,
        .wv_int4 = common,
        .wo_int4 = common,
        .w_gate_up_pair_int4 = pair,
        .w_down_int4 = down,
    };
    @memset(layers, layer);
    return .{
        .allocator = allocator,
        .config = .{
            .dim = dim,
            .hidden_dim = hidden,
            .num_layers = num_layers,
            .vocab_size = vocab_size,
            .num_heads = 1,
            .head_dim = dim,
            .num_kv_heads = 1,
        },
        .source_fingerprint = [_]u8{0x5a} ** 32,
        .layers = layers,
        .weights_arena = arena,
        .final_norm = final_norm,
        .lm_head = &.{},
        .lm_head_int4 = vocabulary,
        .token_embedding = &.{},
        .token_embedding_int4 = vocabulary,
        .prepared_mlp_layout = .pair_nibble,
    };
}

fn testRequests(prompts: *const [width][1]u32) [width]Request {
    var requests: [width]Request = undefined;
    for (&requests, 0..) |*request, lane| {
        request.* = .{
            .prompt = &prompts[lane],
            .max_new_tokens = 1,
            .eos_token = std.math.maxInt(u32),
            .sampler = .{ .temperature = 0 },
            .seed = lane + 1,
        };
    }
    return requests;
}

const TestTxnSink = struct {
    const capacity = 16;

    prepare_count: usize = 0,
    commit_count: usize = 0,
    abort_count: usize = 0,
    reject_sequence: ?u64 = null,
    corrupt_ack_sequence: ?u64 = null,
    prepared: [capacity]token_txn.ProposalV1 = undefined,
    committed: [capacity]token_txn.CommitReceiptV1 = undefined,

    fn sink(self: *@This()) token_txn.SinkV1 {
        return .{
            .context = self,
            .prepare = prepare,
            .commit = commit,
            .abort = abort,
        };
    }

    fn fromContext(context: *anyopaque) *@This() {
        return @ptrCast(@alignCast(context));
    }

    fn prepare(
        context: *anyopaque,
        proposal: *const token_txn.ProposalV1,
        ack: *token_txn.PrepareAckV1,
    ) token_txn.SinkPrepareError!void {
        const self = fromContext(context);
        if (self.prepare_count >= capacity) return error.CapacityExceeded;
        self.prepared[self.prepare_count] = proposal.*;
        self.prepare_count += 1;
        if (self.reject_sequence == proposal.transaction_sequence)
            return error.Unavailable;
        ack.* = .{
            .proposal_sha256 = token_txn.proposalSha256(proposal.*),
            .sink_epoch = 0x5445_5354_5349_4e4b,
            .reservation_id = proposal.transaction_sequence + 1,
        };
        if (self.corrupt_ack_sequence == proposal.transaction_sequence)
            ack.proposal_sha256[0] ^= 0xff;
    }

    fn commit(
        context: *anyopaque,
        receipt: *const token_txn.CommitReceiptV1,
    ) void {
        const self = fromContext(context);
        if (self.commit_count >= capacity)
            @panic("test TokenTxn sink commit capacity exhausted");
        self.committed[self.commit_count] = receipt.*;
        self.commit_count += 1;
    }

    fn abort(
        context: *anyopaque,
        _: *const token_txn.ProposalV1,
        _: *const token_txn.PrepareAckV1,
    ) void {
        const self = fromContext(context);
        self.abort_count += 1;
    }
};

const TestPagedTxnSink = struct {
    const capacity = 32;

    prepare_count: usize = 0,
    commit_count: usize = 0,
    abort_count: usize = 0,
    reject_sequence: ?u64 = null,
    corrupt_ack_sequence: ?u64 = null,
    prepared: [capacity]paged_token_txn.ProposalV1 = undefined,
    committed: [capacity]paged_token_txn.CommitReceiptV1 = undefined,

    fn sink(self: *@This()) paged_token_txn.SinkV1 {
        return .{
            .context = self,
            .prepare = prepare,
            .commit = commit,
            .abort = abort,
        };
    }

    fn fromContext(context: *anyopaque) *@This() {
        return @ptrCast(@alignCast(context));
    }

    fn prepare(
        context: *anyopaque,
        proposal: *const paged_token_txn.ProposalV1,
        ack: *paged_token_txn.PrepareAckV1,
    ) paged_token_txn.SinkPrepareError!void {
        const self = fromContext(context);
        if (self.prepare_count >= capacity) return error.CapacityExceeded;
        self.prepared[self.prepare_count] = proposal.*;
        self.prepare_count += 1;
        if (self.reject_sequence == proposal.transaction_sequence)
            return error.Unavailable;
        ack.* = .{
            .proposal_sha256 = paged_token_txn.proposalSha256(proposal.*),
            .sink_epoch = 0x5041_4745_5349_4e4b,
            .reservation_id = proposal.transaction_sequence + 1,
        };
        if (self.corrupt_ack_sequence == proposal.transaction_sequence)
            ack.proposal_sha256[0] ^= 0xff;
    }

    fn commit(
        context: *anyopaque,
        receipt: *const paged_token_txn.CommitReceiptV1,
    ) void {
        const self = fromContext(context);
        if (self.commit_count >= capacity)
            @panic("test PagedTokenTxn sink commit capacity exhausted");
        self.committed[self.commit_count] = receipt.*;
        self.commit_count += 1;
    }

    fn abort(
        context: *anyopaque,
        _: *const paged_token_txn.ProposalV1,
        _: *const paged_token_txn.PrepareAckV1,
    ) void {
        const self = fromContext(context);
        self.abort_count += 1;
    }
};

const TestPagedElasticTxnSink = struct {
    const capacity = 32;

    prepare_count: usize = 0,
    commit_count: usize = 0,
    abort_count: usize = 0,
    reject_sequence: ?u64 = null,
    corrupt_ack_sequence: ?u64 = null,
    prepared: [capacity]paged_elastic_token_txn.ProposalV2 = undefined,
    committed: [capacity]paged_elastic_token_txn.CommitReceiptV2 = undefined,

    fn sink(self: *@This()) paged_elastic_token_txn.SinkV2 {
        return .{
            .context = self,
            .prepare = prepare,
            .commit = commit,
            .abort = abort,
        };
    }

    fn fromContext(context: *anyopaque) *@This() {
        return @ptrCast(@alignCast(context));
    }

    fn prepare(
        context: *anyopaque,
        proposal: *const paged_elastic_token_txn.ProposalV2,
        ack: *paged_elastic_token_txn.PrepareAckV2,
    ) paged_elastic_token_txn.SinkPrepareError!void {
        const self = fromContext(context);
        if (self.prepare_count >= capacity) return error.CapacityExceeded;
        self.prepared[self.prepare_count] = proposal.*;
        self.prepare_count += 1;
        if (self.reject_sequence == proposal.transaction_sequence)
            return error.Unavailable;
        ack.* = .{
            .proposal_sha256 = paged_elastic_token_txn.proposalSha256(
                proposal.*,
            ),
            .sink_epoch = 0x5043_454c_4153_5449,
            .reservation_id = proposal.transaction_sequence + 1,
        };
        if (self.corrupt_ack_sequence == proposal.transaction_sequence)
            ack.proposal_sha256[0] ^= 0xff;
    }

    fn commit(
        context: *anyopaque,
        receipt: *const paged_elastic_token_txn.CommitReceiptV2,
    ) void {
        const self = fromContext(context);
        if (self.commit_count >= capacity)
            @panic("test PagedElasticTokenTxn sink commit capacity exhausted");
        self.committed[self.commit_count] = receipt.*;
        self.commit_count += 1;
    }

    fn abort(
        context: *anyopaque,
        _: *const paged_elastic_token_txn.ProposalV2,
        _: *const paged_elastic_token_txn.PrepareAckV2,
    ) void {
        const self = fromContext(context);
        self.abort_count += 1;
    }
};

const TestPagedLeaseTxnSink = struct {
    const capacity = 32;

    prepare_count: usize = 0,
    commit_count: usize = 0,
    abort_count: usize = 0,
    reject_sequence: ?u64 = null,
    corrupt_ack_sequence: ?u64 = null,
    prepared: [capacity]paged_lease_token_txn.ProposalV3 = undefined,
    committed: [capacity]paged_lease_token_txn.CommitReceiptV3 = undefined,

    fn sink(self: *@This()) paged_lease_token_txn.SinkV3 {
        return .{
            .context = self,
            .prepare = prepare,
            .commit = commit,
            .abort = abort,
        };
    }

    fn fromContext(context: *anyopaque) *@This() {
        return @ptrCast(@alignCast(context));
    }

    fn prepare(
        context: *anyopaque,
        proposal: *const paged_lease_token_txn.ProposalV3,
        ack: *paged_lease_token_txn.PrepareAckV3,
    ) paged_lease_token_txn.SinkPrepareError!void {
        const self = fromContext(context);
        if (self.prepare_count >= capacity) return error.CapacityExceeded;
        self.prepared[self.prepare_count] = proposal.*;
        self.prepare_count += 1;
        if (self.reject_sequence == proposal.transaction_sequence)
            return error.Unavailable;
        ack.* = .{
            .proposal_sha256 = paged_lease_token_txn.proposalSha256(
                proposal.*,
            ),
            .sink_epoch = 0x5043_4c45_4153_4533,
            .reservation_id = proposal.transaction_sequence + 1,
        };
        if (self.corrupt_ack_sequence == proposal.transaction_sequence)
            ack.proposal_sha256[0] ^= 0xff;
    }

    fn commit(
        context: *anyopaque,
        receipt: *const paged_lease_token_txn.CommitReceiptV3,
    ) void {
        const self = fromContext(context);
        if (self.commit_count >= capacity)
            @panic("test PagedLeaseTokenTxn sink commit capacity exhausted");
        self.committed[self.commit_count] = receipt.*;
        self.commit_count += 1;
    }

    fn abort(
        context: *anyopaque,
        _: *const paged_lease_token_txn.ProposalV3,
        _: *const paged_lease_token_txn.PrepareAckV3,
    ) void {
        const self = fromContext(context);
        self.abort_count += 1;
    }
};

const TestPagedLeaseWaveObserver = struct {
    const capacity = 32;

    count: usize = 0,
    evidence: [capacity]PagedLeaseWaveEvidenceV1 = undefined,

    fn observer(self: *@This()) PagedLeaseWaveObserver {
        return .{
            .context = self,
            .observe = observe,
        };
    }

    fn observe(
        context: *anyopaque,
        evidence: *const PagedLeaseWaveEvidenceV1,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.count >= capacity)
            @panic("test paged lease wave observer capacity exhausted");
        self.evidence[self.count] = evidence.*;
        self.count += 1;
    }
};

const TestPagedLeaseAdmissionObserver = struct {
    count: usize = 0,
    evidence: PagedLeaseAdmissionFailureV1 = undefined,

    fn observer(self: *@This()) PagedLeaseAdmissionObserver {
        return .{
            .context = self,
            .observe = observe,
        };
    }

    fn observe(
        context: *anyopaque,
        evidence: *const PagedLeaseAdmissionFailureV1,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.count != 0)
            @panic("test paged lease admission observer called twice");
        self.evidence = evidence.*;
        self.count = 1;
    }
};

test "PagedLease observers are LeaseTree-only and ABI-fenced in preflight" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var model = try testPreparedModelLayers(68, 2);
    defer model.deinit();
    const prompts = [width][1]u32{ .{0}, .{1}, .{2}, .{3} };
    const requests = testRequests(&prompts);
    var lease_sink: TestPagedLeaseTxnSink = .{};
    var wave: TestPagedLeaseWaveObserver = .{};
    var admission: TestPagedLeaseAdmissionObserver = .{};
    const lease_options: Options = .{
        .num_threads = 2,
        .kv_cache_mode = .paged16_required,
        .paged_admission_mode = .lease_tree_required,
        .kv_capacity_positions = paged_kv.page_positions + 1,
        .paged_lease_token_txn_publication = .{
            .request_epoch = 0x5032_4f42_5345_0001,
            .sink = lease_sink.sink(),
        },
    };

    var wrong_wave = wave.observer();
    wrong_wave.abi_version +%= 1;
    var options = lease_options;
    options.paged_lease_wave_observer = wrong_wave;
    try std.testing.expectError(
        generate_api.GenerateError.TokenTransactionRejected,
        preflight(model, requests, options),
    );

    var wrong_admission = admission.observer();
    wrong_admission.abi_version +%= 1;
    options = lease_options;
    options.paged_lease_admission_observer = wrong_admission;
    try std.testing.expectError(
        generate_api.GenerateError.TokenTransactionRejected,
        preflight(model, requests, options),
    );

    var flat_sink: TestPagedTxnSink = .{};
    options = .{
        .num_threads = 2,
        .kv_cache_mode = .paged16_required,
        .kv_capacity_positions = paged_kv.page_positions + 1,
        .paged_token_txn_publication = .{
            .request_epoch = 0x5032_4f42_5345_0002,
            .sink = flat_sink.sink(),
        },
        .paged_lease_wave_observer = wave.observer(),
    };
    try std.testing.expectError(
        generate_api.GenerateError.TokenTransactionRejected,
        preflight(model, requests, options),
    );

    options = .{ .paged_lease_admission_observer = admission.observer() };
    try std.testing.expectError(
        generate_api.GenerateError.TokenTransactionRejected,
        preflight(model, requests, options),
    );
    try std.testing.expectEqual(@as(usize, 0), wave.count);
    try std.testing.expectEqual(@as(usize, 0), admission.count);
}

const SessionStealObserver = struct {
    bank: *resource_bank.Bank,
    attempted_epoch: u64,
    attacker: token_txn.Session = .{},
    called: bool = false,
    stole_session: bool = false,
    rejected_by_fence: bool = false,

    fn observer(self: *@This()) generate_api.ResourceCommitObserver {
        return .{
            .context = self,
            .observe = observe,
        };
    }

    fn observe(
        raw_context: *anyopaque,
        evidence: *const generate_api.ResourceCommitEvidenceV1,
    ) generate_api.ResourceCommitObserverError!void {
        const self: *@This() = @ptrCast(@alignCast(raw_context));
        self.called = true;
        self.attacker.init(
            self.bank,
            evidence.receipt,
            self.attempted_epoch,
        ) catch |err| {
            self.rejected_by_fence = err == error.InvalidState;
            return error.Unavailable;
        };
        self.stole_session = true;
        return error.Unavailable;
    }
};

test "cohort owner key binds every schedule ABI and mode" {
    var model = try testPreparedModel(68);
    defer model.deinit();
    const prompts = [width][1]u32{ .{0}, .{1}, .{2}, .{3} };
    const requests = testRequests(&prompts);
    const base: CohortScheduleIdentity = .{
        .greedy_head_mode = .materialized,
        .attention_mode = .serial,
    };
    var projection_changed = base;
    projection_changed.projection_wave_abi_version +%= 1;
    var shared_abi_changed = base;
    shared_abi_changed.shared_kv_attention_abi_version +%= 1;
    var pair_down_abi_changed = base;
    pair_down_abi_changed.pair_down_wave_abi_version +%= 1;
    var greedy_abi_changed = base;
    greedy_abi_changed.greedy_head_abi_version +%= 1;
    var decode_abi_changed = base;
    decode_abi_changed.decode_lane4_abi +%= 1;
    var token_txn_abi_changed = base;
    token_txn_abi_changed.token_txn_abi_version +%= 1;
    var token_txn_sink_abi_changed = base;
    token_txn_sink_abi_changed.token_txn_sink_abi_version +%= 1;
    var shared_mode = base;
    shared_mode.attention_mode = .shared_kv_required;
    var streaming_mode = base;
    streaming_mode.greedy_head_mode = .streaming_required;
    var pair_down_mode = base;
    pair_down_mode.pair_down_mode = .single_epoch_required;
    var publication_mode = base;
    publication_mode.publication_mode = .token_txn_required;

    const identities = [_]CohortScheduleIdentity{
        base,
        projection_changed,
        shared_abi_changed,
        pair_down_abi_changed,
        greedy_abi_changed,
        decode_abi_changed,
        token_txn_abi_changed,
        token_txn_sink_abi_changed,
        shared_mode,
        streaming_mode,
        pair_down_mode,
        publication_mode,
    };
    var keys: [identities.len]u64 = undefined;
    for (identities, 0..) |identity, index| {
        keys[index] = cohortOwnerKeyBound(model, requests, 4, identity);
        try std.testing.expect(keys[index] != 0);
        for (keys[0..index]) |previous|
            try std.testing.expect(previous != keys[index]);
    }
}

test "TokenTxn B4 atomically matches legacy through heterogeneous retirement" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var model = try testPreparedModel(68);
    defer model.deinit();
    const prompts = [width][1]u32{ .{0}, .{1}, .{2}, .{3} };
    var requests = testRequests(&prompts);
    for (&requests, 0..) |*request, lane| {
        request.max_new_tokens = width - lane;
        request.sampler = .{
            .temperature = 0.8,
            .top_k = 16,
            .top_p = 0.9,
        };
    }

    const legacy_options: Options = .{ .num_threads = 2 };
    const claim = try deriveResourceClaim(model, requests, legacy_options);
    var legacy_slots: [width]resource_bank.Slot = undefined;
    var legacy_bank = try resource_bank.Bank.init(
        &legacy_slots,
        .{
            .host_bytes = try claim.hostBytes(),
            .logits_bytes = claim.logits_bytes,
            .queue_slots = width,
        },
        0x5458_4e4c_4547_0001,
    );
    var legacy_telemetry: Telemetry = .{};
    var legacy = try generate(
        std.testing.allocator,
        model,
        requests,
        .{
            .num_threads = 2,
            .request_resource_bank = &legacy_bank,
            .telemetry = &legacy_telemetry,
        },
    );
    defer legacy.deinit();

    var sink: TestTxnSink = .{};
    const request_epoch: u64 = 0x5458_4e5f_4234_0001;
    const strict_options: Options = .{
        .num_threads = 2,
        .token_txn_publication = .{
            .request_epoch = request_epoch,
            .sink = sink.sink(),
        },
    };
    try std.testing.expectEqual(
        claim,
        try deriveResourceClaim(model, requests, strict_options),
    );
    var strict_slots: [width]resource_bank.Slot = undefined;
    var strict_bank = try resource_bank.Bank.init(
        &strict_slots,
        .{
            .host_bytes = try claim.hostBytes(),
            .logits_bytes = claim.logits_bytes,
            .queue_slots = width,
        },
        0x5458_4e53_5452_0001,
    );
    var strict_telemetry: Telemetry = .{};
    var strict = try generate(
        std.testing.allocator,
        model,
        requests,
        .{
            .num_threads = 2,
            .request_resource_bank = &strict_bank,
            .token_txn_publication = .{
                .request_epoch = request_epoch,
                .sink = sink.sink(),
            },
            .telemetry = &strict_telemetry,
        },
    );
    defer strict.deinit();

    for (0..width) |lane|
        try std.testing.expectEqualSlices(
            u32,
            legacy.tokens(lane),
            strict.tokens(lane),
        );
    try std.testing.expectEqualDeep(
        legacy_telemetry.lane_states,
        strict_telemetry.lane_states,
    );
    try std.testing.expectEqual(@as(usize, width), sink.prepare_count);
    try std.testing.expectEqual(@as(usize, width), sink.commit_count);
    try std.testing.expectEqual(@as(usize, 0), sink.abort_count);

    const expected_masks = [_]u8{ 0b1111, 0b0111, 0b0011, 0b0001 };
    for (sink.committed[0..sink.commit_count], 0..) |receipt, sequence| {
        const proposal = receipt.proposal;
        try std.testing.expectEqual(request_epoch, proposal.request_epoch);
        try std.testing.expectEqual(@as(u64, @intCast(sequence)), proposal.transaction_sequence);
        try std.testing.expectEqual(expected_masks[sequence], proposal.live_mask);
        try std.testing.expectEqual(@popCount(expected_masks[sequence]), proposal.live_lane_count);
        try std.testing.expectEqualDeep(sink.prepared[sequence], proposal);
        try std.testing.expectEqual(
            token_txn.proposalSha256(proposal),
            receipt.proposal_sha256,
        );
        try std.testing.expectEqual(
            token_txn.commitSha256(
                receipt.proposal_sha256,
                receipt.prepare_ack,
            ),
            receipt.commit_sha256,
        );
        for (0..width) |lane| {
            const live = proposal.live_mask &
                (@as(u8, 1) << @intCast(lane)) != 0;
            if (!live) continue;
            const lane_proposal = proposal.lanes[lane];
            try std.testing.expectEqual(@as(u64, @intCast(sequence)), lane_proposal.step_index);
            try std.testing.expectEqual(sequence != 0, lane_proposal.has_kv_transition);
            try std.testing.expectEqual(
                sequence + 1 == requests[lane].max_new_tokens,
                lane_proposal.terminal,
            );
        }
    }

    try std.testing.expectEqual(PublicationMode.token_txn_required, strict_telemetry.publication_mode);
    try std.testing.expectEqual(request_epoch, strict_telemetry.token_txn_request_epoch);
    try std.testing.expectEqual(token_txn.abi, strict_telemetry.token_txn_abi_version);
    try std.testing.expectEqual(token_txn.sink_abi, strict_telemetry.token_txn_sink_abi_version);
    try std.testing.expectEqual(@as(usize, width), strict_telemetry.token_txn_commits);
    try std.testing.expectEqual(@as(usize, 10), strict_telemetry.token_txn_lane_commits);
    try std.testing.expectEqual(@as(usize, 1), strict_telemetry.token_txn_first_token_commits);
    try std.testing.expectEqual(@as(usize, 6), strict_telemetry.token_txn_kv_row_commits);
    try std.testing.expectEqual(@as(usize, 0), strict_telemetry.token_txn_aborts);
    try std.testing.expectEqual(@as(usize, 0), strict_telemetry.token_txn_provisional_aborts);
    try std.testing.expectEqual(@as(usize, 0), strict_telemetry.token_txn_sink_rejects);
    try std.testing.expectEqual(@as(u64, width - 1), strict_telemetry.token_txn_last_sequence);

    const legacy_snapshot = try legacy_bank.snapshot();
    const strict_snapshot = try strict_bank.snapshot();
    try std.testing.expect(legacy_snapshot.used.isZero());
    try std.testing.expect(strict_snapshot.used.isZero());
    try std.testing.expectEqual(@as(usize, 0), strict_snapshot.active_reservations);
    try std.testing.expectEqual(@as(usize, 0), strict_snapshot.committed_receipts);
    try std.testing.expectEqual(@as(u64, 1), strict_snapshot.releases);
}

test "PagedTokenTxn B4 matches contiguous state with lazy capacity envelope" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var model = try testPreparedModelLayers(68, 2);
    defer model.deinit();
    const prompts = [width][1]u32{ .{0}, .{1}, .{2}, .{3} };
    var requests = testRequests(&prompts);
    for (&requests, 0..) |*request, lane| {
        request.max_new_tokens = width - lane;
        request.sampler = .{
            .temperature = 0.8,
            .top_k = 16,
            .top_p = 0.9,
        };
    }

    const capacity_positions: usize = 17;
    var contiguous_sink: TestTxnSink = .{};
    const contiguous_options: Options = .{
        .num_threads = 2,
        .kv_capacity_positions = capacity_positions,
        .token_txn_publication = .{
            .request_epoch = 0x5032_4243_4f4e_0001,
            .sink = contiguous_sink.sink(),
        },
    };
    const contiguous_claim = try deriveResourceClaim(
        model,
        requests,
        contiguous_options,
    );
    var contiguous_slots: [width]resource_bank.Slot = undefined;
    var contiguous_bank = try resource_bank.Bank.init(
        &contiguous_slots,
        .{
            .host_bytes = try contiguous_claim.hostBytes(),
            .kv_bytes = contiguous_claim.kv_bytes,
            .logits_bytes = contiguous_claim.logits_bytes,
            .queue_slots = width,
        },
        0x5032_4243_4f4e_0002,
    );
    var contiguous_telemetry: Telemetry = .{};
    var contiguous = try generate(
        std.testing.allocator,
        model,
        requests,
        .{
            .num_threads = 2,
            .kv_capacity_positions = capacity_positions,
            .request_resource_bank = &contiguous_bank,
            .token_txn_publication = .{
                .request_epoch = 0x5032_4243_4f4e_0001,
                .sink = contiguous_sink.sink(),
            },
            .telemetry = &contiguous_telemetry,
        },
    );
    defer contiguous.deinit();

    var paged_sink: TestPagedTxnSink = .{};
    const paged_options: Options = .{
        .num_threads = 2,
        .kv_cache_mode = .paged16_required,
        .kv_capacity_positions = capacity_positions,
        .paged_token_txn_publication = .{
            .request_epoch = 0x5032_4250_4147_0001,
            .sink = paged_sink.sink(),
        },
    };
    const paged_claim = try deriveResourceClaim(model, requests, paged_options);
    var paged_slots: [width]resource_bank.Slot = undefined;
    var paged_bank = try resource_bank.Bank.init(
        &paged_slots,
        .{
            .host_bytes = try paged_claim.hostBytes(),
            .kv_bytes = paged_claim.kv_bytes,
            .logits_bytes = paged_claim.logits_bytes,
            .queue_slots = width,
        },
        0x5032_4250_4147_0002,
    );
    var paged_telemetry: Telemetry = .{};
    var paged = try generate(
        std.testing.allocator,
        model,
        requests,
        .{
            .num_threads = 2,
            .kv_cache_mode = .paged16_required,
            .kv_capacity_positions = capacity_positions,
            .request_resource_bank = &paged_bank,
            .paged_token_txn_publication = .{
                .request_epoch = 0x5032_4250_4147_0001,
                .sink = paged_sink.sink(),
            },
            .telemetry = &paged_telemetry,
        },
    );
    defer paged.deinit();

    for (0..width) |lane|
        try std.testing.expectEqualSlices(
            u32,
            contiguous.tokens(lane),
            paged.tokens(lane),
        );
    try std.testing.expectEqualDeep(
        contiguous_telemetry.lane_states,
        paged_telemetry.lane_states,
    );
    try std.testing.expectEqual(@as(usize, width), paged_sink.prepare_count);
    try std.testing.expectEqual(@as(usize, width), paged_sink.commit_count);
    try std.testing.expectEqual(@as(usize, 0), paged_sink.abort_count);

    var prior_chains = [_]paged_token_txn.Digest{
        [_]u8{0} ** 32,
    } ** width;
    const expected_masks = [_]u8{ 0b1111, 0b0111, 0b0011, 0b0001 };
    for (paged_sink.committed[0..paged_sink.commit_count], 0..) |receipt, sequence| {
        const proposal = receipt.proposal;
        try std.testing.expectEqual(paged_decode_abi, proposal.execution_abi);
        try std.testing.expectEqual(paged_claim.kv_bytes, proposal.kv_capacity_bytes);
        try std.testing.expectEqual(expected_masks[sequence], proposal.live_mask);
        try std.testing.expectEqualDeep(
            paged_sink.prepared[sequence],
            proposal,
        );
        try std.testing.expectEqual(
            paged_token_txn.proposalSha256(proposal),
            receipt.proposal_sha256,
        );
        try std.testing.expectEqual(
            paged_token_txn.commitSha256(
                receipt.proposal_sha256,
                receipt.prepare_ack,
            ),
            receipt.commit_sha256,
        );
        for (0..width) |lane| {
            if (proposal.live_mask &
                (@as(u8, 1) << @intCast(lane)) == 0) continue;
            const transition = proposal.lanes[lane].kv_transition;
            if (sequence == 0) {
                try std.testing.expect(!proposal.lanes[lane].has_kv_transition);
                try std.testing.expectEqual(
                    transition.root_before_generation,
                    transition.root_after_generation,
                );
                try std.testing.expectEqual(
                    transition.state_chain_before,
                    transition.state_chain_after,
                );
            } else {
                try std.testing.expect(proposal.lanes[lane].has_kv_transition);
                try std.testing.expectEqual(
                    prior_chains[lane],
                    transition.state_chain_before,
                );
                try std.testing.expectEqual(
                    transition.root_before_len + 1,
                    transition.root_after_len,
                );
                try std.testing.expect(!std.mem.eql(
                    u8,
                    &transition.state_chain_before,
                    &transition.state_chain_after,
                ));
            }
            prior_chains[lane] = transition.state_chain_after;
        }
    }

    const lane_capacity = try paged_kv.deriveCapacityLedger(
        model.config.num_layers,
        model.config.num_kv_heads * model.config.head_dim,
        capacity_positions,
    );
    try std.testing.expectEqual(
        lane_capacity.allocation_capacity_bytes * width,
        paged_telemetry.paged_kv_capacity_bytes,
    );
    try std.testing.expectEqual(
        paged_claim.kv_bytes,
        @as(u64, @intCast(paged_telemetry.paged_kv_capacity_bytes)),
    );
    try std.testing.expect(
        paged_telemetry.paged_kv_resident_bytes <
            paged_telemetry.paged_kv_capacity_bytes,
    );
    try std.testing.expectEqual(
        PublicationMode.paged_token_txn_required,
        paged_telemetry.publication_mode,
    );
    try std.testing.expectEqual(
        KvCacheMode.paged16_required,
        paged_telemetry.kv_cache_mode,
    );
    try std.testing.expectEqual(
        @as(usize, 6),
        paged_telemetry.paged_root_commits,
    );

    const contiguous_snapshot = try contiguous_bank.snapshot();
    const paged_snapshot = try paged_bank.snapshot();
    try std.testing.expect(contiguous_snapshot.used.isZero());
    try std.testing.expect(paged_snapshot.used.isZero());
    try std.testing.expectEqual(@as(u64, 1), paged_snapshot.releases);
}

test "PagedElasticTokenTxn admits allocator commitment instead of capacity" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var model = try testPreparedModelLayers(68, 2);
    defer model.deinit();
    const prompts = [width][1]u32{ .{0}, .{1}, .{2}, .{3} };
    var requests = testRequests(&prompts);
    for (&requests, 0..) |*request, lane| {
        request.max_new_tokens = width - lane;
        request.sampler = .{
            .temperature = 0.8,
            .top_k = 16,
            .top_p = 0.9,
        };
    }

    const capacity_positions: usize = 17;
    var flat_sink: TestPagedTxnSink = .{};
    const flat_options: Options = .{
        .num_threads = 2,
        .kv_cache_mode = .paged16_required,
        .kv_capacity_positions = capacity_positions,
        .paged_token_txn_publication = .{
            .request_epoch = 0x5032_4346_4c41_0001,
            .sink = flat_sink.sink(),
        },
    };
    const flat_claim = try deriveResourceClaim(model, requests, flat_options);
    var flat_slots: [width]resource_bank.Slot = undefined;
    var flat_bank = try resource_bank.Bank.init(
        &flat_slots,
        .{
            .host_bytes = try flat_claim.hostBytes(),
            .kv_bytes = flat_claim.kv_bytes,
            .logits_bytes = flat_claim.logits_bytes,
            .queue_slots = width,
        },
        0x5032_4346_4c41_0002,
    );
    var flat_telemetry: Telemetry = .{};
    var flat = try generate(
        std.testing.allocator,
        model,
        requests,
        .{
            .num_threads = 2,
            .kv_cache_mode = .paged16_required,
            .kv_capacity_positions = capacity_positions,
            .request_resource_bank = &flat_bank,
            .paged_token_txn_publication = .{
                .request_epoch = 0x5032_4346_4c41_0001,
                .sink = flat_sink.sink(),
            },
            .telemetry = &flat_telemetry,
        },
    );
    defer flat.deinit();

    var elastic_sink: TestPagedElasticTxnSink = .{};
    const elastic_options: Options = .{
        .num_threads = 2,
        .kv_cache_mode = .paged16_required,
        .paged_admission_mode = .resident_child_required,
        .kv_capacity_positions = capacity_positions,
        .paged_elastic_token_txn_publication = .{
            .request_epoch = 0x5032_4345_4c41_0001,
            .sink = elastic_sink.sink(),
        },
    };
    const envelope = try deriveResourceAdmissionEnvelope(
        model,
        requests,
        elastic_options,
    );
    try std.testing.expect(
        envelope.parent_claim.kv_bytes < envelope.bounded_peak_claim.kv_bytes,
    );
    try std.testing.expect(
        envelope.bounded_peak_claim.kv_bytes <
            envelope.logical_kv_capacity_bytes,
    );
    try std.testing.expectEqual(
        envelope.parent_claim.kv_bytes,
        envelope.page_map_bytes,
    );
    var elastic_slots: [width]resource_bank.Slot = undefined;
    var elastic_child_slots: [width]resource_bank.ChildSlot = undefined;
    var elastic_bank = try resource_bank.Bank.initWithChildSlots(
        &elastic_slots,
        &elastic_child_slots,
        .{
            .host_bytes = try envelope.bounded_peak_claim.hostBytes(),
            .kv_bytes = envelope.bounded_peak_claim.kv_bytes,
            .logits_bytes = envelope.parent_claim.logits_bytes,
            .queue_slots = width,
        },
        0x5032_4345_4c41_0002,
    );
    var elastic_telemetry: Telemetry = .{};
    var resources: generate_api.RequestResourceTelemetry = .{};
    var elastic = try generate(
        std.testing.allocator,
        model,
        requests,
        .{
            .num_threads = 2,
            .kv_cache_mode = .paged16_required,
            .paged_admission_mode = .resident_child_required,
            .kv_capacity_positions = capacity_positions,
            .request_resource_bank = &elastic_bank,
            .resource_telemetry = &resources,
            .paged_elastic_token_txn_publication = .{
                .request_epoch = 0x5032_4345_4c41_0001,
                .sink = elastic_sink.sink(),
            },
            .telemetry = &elastic_telemetry,
        },
    );
    defer elastic.deinit();

    for (0..width) |lane|
        try std.testing.expectEqualSlices(
            u32,
            flat.tokens(lane),
            elastic.tokens(lane),
        );
    try std.testing.expectEqualDeep(
        flat_telemetry.lane_states,
        elastic_telemetry.lane_states,
    );
    try std.testing.expectEqual(
        PublicationMode.paged_elastic_token_txn_required,
        elastic_telemetry.publication_mode,
    );
    try std.testing.expectEqual(
        PagedAdmissionMode.resident_child_required,
        elastic_telemetry.paged_admission_mode,
    );
    try std.testing.expectEqual(
        envelope.logical_kv_capacity_bytes,
        elastic_telemetry.paged_kv_logical_capacity_bytes,
    );
    try std.testing.expectEqual(
        envelope.bounded_peak_payload_bytes,
        elastic_telemetry.paged_kv_child_current_bytes,
    );
    try std.testing.expectEqual(@as(usize, 1), elastic_telemetry.paged_kv_child_growth_events);
    try std.testing.expectEqual(@as(usize, width), elastic_sink.commit_count);
    for (elastic_sink.committed[0..elastic_sink.commit_count]) |receipt| {
        try std.testing.expectEqual(
            paged_resident_decode_abi,
            receipt.proposal.execution_abi,
        );
        try std.testing.expectEqual(
            envelope.logical_kv_capacity_bytes,
            receipt.proposal.logical_kv_capacity_bytes,
        );
        try std.testing.expectEqual(
            envelope.page_map_bytes,
            receipt.proposal.page_map_bytes,
        );
        try std.testing.expectEqual(
            envelope.bounded_peak_payload_bytes,
            receipt.proposal.resident_payload_bytes,
        );
        try std.testing.expectEqualDeep(
            envelope.parent_claim,
            receipt.proposal.parent_receipt.claim,
        );
    }
    const snapshot = try elastic_bank.snapshotV2();
    try std.testing.expect(snapshot.used.isZero());
    try std.testing.expectEqual(@as(usize, 0), snapshot.active_child_leases);
    try std.testing.expectEqual(@as(u64, 1), snapshot.child_opens);
    try std.testing.expectEqual(@as(u64, 1), snapshot.child_grows);
    try std.testing.expectEqual(@as(u64, 1), snapshot.child_closes);
    try std.testing.expectEqual(@as(u64, 1), snapshot.releases);
    try std.testing.expectEqual(
        envelope.bounded_peak_claim.kv_bytes,
        snapshot.peak.kv_bytes,
    );
    try std.testing.expectEqual(resource_bank.child_lease_abi, resources.child_lease_abi_version);
    try std.testing.expectEqual(envelope.logical_kv_capacity_bytes, resources.logical_kv_capacity_bytes);
    try std.testing.expectEqual(@as(usize, 0), resources.active_child_leases);
}

test "PagedLeaseTokenTxn reclaims heterogeneous EOS pages without changing results" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var model = try testPreparedModelLayers(68, 2);
    defer model.deinit();
    const prompts = [width][1]u32{ .{0}, .{1}, .{2}, .{3} };
    const forced = [width][width]u32{
        .{ 7, 1, 1, 1 },
        .{ 1, 7, 1, 1 },
        .{ 1, 1, 7, 1 },
        .{ 1, 1, 1, 7 },
    };
    var requests = testRequests(&prompts);
    for (&requests, 0..) |*request, lane| {
        request.max_new_tokens = width;
        request.eos_token = 7;
        request.forced_tokens = &forced[lane];
    }

    const capacity_positions = paged_kv.page_positions + 1;
    var retained_sink: TestPagedLeaseTxnSink = .{};
    var retained_wave_observer: TestPagedLeaseWaveObserver = .{};
    const retained_options: Options = .{
        .num_threads = 2,
        .kv_cache_mode = .paged16_required,
        .paged_admission_mode = .lease_tree_required,
        .lease_reclaim_policy = .retain_until_teardown,
        .kv_capacity_positions = capacity_positions,
        .paged_lease_token_txn_publication = .{
            .request_epoch = 0x5032_434c_5254_0001,
            .sink = retained_sink.sink(),
        },
        .paged_lease_wave_observer = retained_wave_observer.observer(),
    };
    const retained_envelope = try deriveResourceAdmissionEnvelope(
        model,
        requests,
        retained_options,
    );
    try std.testing.expectEqual(
        PagedAdmissionMode.lease_tree_required,
        retained_envelope.paged_admission_mode,
    );
    try std.testing.expectEqual(@as(u32, 1), retained_envelope.required_lease_roots);
    try std.testing.expect(retained_envelope.required_lease_nodes <= 64);
    try std.testing.expectEqual(
        retained_envelope.parent_claim.capsule_bytes,
        retained_envelope.binding_storage_bytes,
    );
    try std.testing.expectEqual(
        retained_envelope.parent_claim.kv_bytes,
        retained_envelope.page_map_bytes,
    );

    var retained_slots = [_]resource_bank.Slot{.{}} ** 1;
    var retained_roots = [_]resource_bank.LeaseTreeRootSlot{.{}} ** 1;
    var retained_nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 64;
    const retained_node_count: usize = @intCast(
        retained_envelope.required_lease_nodes,
    );
    var retained_bank = try resource_bank.Bank.initWithLeaseTree(
        &retained_slots,
        &retained_roots,
        retained_nodes[0..retained_node_count],
        .{
            .host_bytes = try retained_envelope.bounded_peak_claim.hostBytes(),
            .kv_bytes = retained_envelope.bounded_peak_claim.kv_bytes,
            .queue_slots = width,
        },
        0x5032_434c_5254_0002,
    );
    var retained_telemetry: Telemetry = .{};
    var retained_run_options = retained_options;
    retained_run_options.request_resource_bank = &retained_bank;
    retained_run_options.telemetry = &retained_telemetry;
    var retained = try generate(
        std.testing.allocator,
        model,
        requests,
        retained_run_options,
    );
    defer retained.deinit();

    var retained_tokens =
        [_][width]u32{[_]u32{0} ** width} ** width;
    for (0..width) |lane| {
        const tokens = retained.tokens(lane);
        try std.testing.expectEqual(lane + 1, tokens.len);
        @memcpy(retained_tokens[lane][0..tokens.len], tokens);
    }
    const retained_lengths = retained.lengths;
    const retained_states = retained_telemetry.lane_states;
    try std.testing.expectEqual(@as(usize, width), retained_sink.prepare_count);
    try std.testing.expectEqual(@as(usize, width), retained_sink.commit_count);
    try std.testing.expectEqual(@as(usize, 0), retained_sink.abort_count);
    try std.testing.expectEqual(width, retained_wave_observer.count);
    try std.testing.expectEqual(@as(usize, width), retained_telemetry.paged_lease_terminal_lanes);
    try std.testing.expectEqual(@as(usize, 0), retained_telemetry.paged_lease_reclaimed_lanes);
    try std.testing.expectEqual(
        retained_envelope.bounded_peak_payload_bytes,
        retained_telemetry.paged_lease_retained_payload_bytes,
    );
    try std.testing.expect((try retained_bank.snapshotV3()).used.isZero());

    // Independent flat PagedTokenTxn oracle: this uses neither LeaseTree nor
    // the v3 coordinator/session, so equal tokens and terminal state evidence
    // catch bugs shared by the two v3 reclaim policies.
    var oracle_sink: TestPagedTxnSink = .{};
    const oracle_options: Options = .{
        .num_threads = 2,
        .kv_cache_mode = .paged16_required,
        .kv_capacity_positions = capacity_positions,
        .paged_token_txn_publication = .{
            .request_epoch = 0x5032_434c_4f52_0001,
            .sink = oracle_sink.sink(),
        },
    };
    const oracle_claim = try deriveResourceClaim(
        model,
        requests,
        oracle_options,
    );
    var oracle_slots = [_]resource_bank.Slot{.{}} ** 1;
    var oracle_bank = try resource_bank.Bank.init(
        &oracle_slots,
        .{
            .host_bytes = try oracle_claim.hostBytes(),
            .kv_bytes = oracle_claim.kv_bytes,
            .queue_slots = width,
        },
        0x5032_434c_4f52_0002,
    );
    var oracle_telemetry: Telemetry = .{};
    var oracle_run_options = oracle_options;
    oracle_run_options.request_resource_bank = &oracle_bank;
    oracle_run_options.telemetry = &oracle_telemetry;
    var oracle = try generate(
        std.testing.allocator,
        model,
        requests,
        oracle_run_options,
    );
    defer oracle.deinit();
    for (0..width) |lane|
        try std.testing.expectEqualSlices(
            u32,
            retained_tokens[lane][0..retained_lengths[lane]],
            oracle.tokens(lane),
        );
    try std.testing.expectEqualDeep(
        retained_states,
        oracle_telemetry.lane_states,
    );
    try std.testing.expectEqual(@as(usize, width), oracle_sink.commit_count);
    try std.testing.expect((try oracle_bank.snapshot()).used.isZero());

    var immediate_sink: TestPagedLeaseTxnSink = .{};
    var immediate_wave_observer: TestPagedLeaseWaveObserver = .{};
    var immediate_options = retained_options;
    immediate_options.lease_reclaim_policy = .terminal_immediate;
    immediate_options.paged_lease_token_txn_publication = .{
        .request_epoch = 0x5032_434c_494d_0001,
        .sink = immediate_sink.sink(),
    };
    immediate_options.paged_lease_wave_observer =
        immediate_wave_observer.observer();
    const immediate_envelope = try deriveResourceAdmissionEnvelope(
        model,
        requests,
        immediate_options,
    );
    try std.testing.expectEqualDeep(retained_envelope, immediate_envelope);
    var immediate_slots = [_]resource_bank.Slot{.{}} ** 1;
    var immediate_roots = [_]resource_bank.LeaseTreeRootSlot{.{}} ** 1;
    var immediate_nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 64;
    const immediate_node_count: usize = @intCast(
        immediate_envelope.required_lease_nodes,
    );
    var immediate_bank = try resource_bank.Bank.initWithLeaseTree(
        &immediate_slots,
        &immediate_roots,
        immediate_nodes[0..immediate_node_count],
        .{
            .host_bytes = try immediate_envelope.bounded_peak_claim.hostBytes(),
            .kv_bytes = immediate_envelope.bounded_peak_claim.kv_bytes,
            .queue_slots = width,
        },
        0x5032_434c_494d_0002,
    );
    var immediate_telemetry: Telemetry = .{};
    var immediate_run_options = immediate_options;
    immediate_run_options.request_resource_bank = &immediate_bank;
    immediate_run_options.telemetry = &immediate_telemetry;
    var immediate = try generate(
        std.testing.allocator,
        model,
        requests,
        immediate_run_options,
    );
    defer immediate.deinit();

    try std.testing.expectEqualDeep(retained_lengths, immediate.lengths);
    for (0..width) |lane|
        try std.testing.expectEqualSlices(
            u32,
            retained_tokens[lane][0..retained_lengths[lane]],
            immediate.tokens(lane),
        );
    try std.testing.expectEqualDeep(
        retained_states,
        immediate_telemetry.lane_states,
    );
    try std.testing.expectEqual(@as(usize, width), immediate_sink.prepare_count);
    try std.testing.expectEqual(@as(usize, width), immediate_sink.commit_count);
    try std.testing.expectEqual(@as(usize, 0), immediate_sink.abort_count);
    try std.testing.expectEqual(@as(usize, width), immediate_telemetry.paged_lease_terminal_lanes);
    try std.testing.expectEqual(@as(usize, width), immediate_telemetry.paged_lease_reclaimed_lanes);
    try std.testing.expectEqual(
        immediate_envelope.bounded_peak_payload_bytes,
        immediate_telemetry.paged_lease_reclaimed_payload_bytes,
    );
    try std.testing.expectEqual(@as(usize, 0), immediate_telemetry.paged_lease_retained_payload_bytes);
    try std.testing.expectEqual(
        PublicationMode.paged_lease_token_txn_required,
        immediate_telemetry.publication_mode,
    );
    try std.testing.expectEqual(
        paged_lease_token_txn.abi,
        immediate_telemetry.paged_lease_token_txn_abi_version,
    );
    try std.testing.expectEqual(width, immediate_wave_observer.count);

    const lane_ledger = try paged_kv.deriveCapacityLedger(
        model.config.num_layers,
        model.config.num_kv_heads * model.config.head_dim,
        capacity_positions,
    );
    const page_payload_bytes: u64 = @intCast(lane_ledger.page_payload_bytes);
    const expected_masks = [_]u8{ 0b1111, 0b1110, 0b1100, 0b1000 };
    for (0..width) |sequence| {
        const retained_receipt = retained_sink.committed[sequence];
        const immediate_receipt = immediate_sink.committed[sequence];
        try std.testing.expectEqual(
            expected_masks[sequence],
            retained_receipt.proposal.live_mask,
        );
        try std.testing.expectEqual(
            expected_masks[sequence],
            immediate_receipt.proposal.live_mask,
        );
        try std.testing.expectEqual(
            page_payload_bytes * width,
            retained_receipt.proposal.tree.current.kv_bytes,
        );
        try std.testing.expectEqual(
            page_payload_bytes * (width - sequence),
            immediate_receipt.proposal.tree.current.kv_bytes,
        );
        const wave = immediate_wave_observer.evidence[sequence];
        const retained_wave = retained_wave_observer.evidence[sequence];
        const terminal_mask = @as(u8, 1) << @intCast(sequence);
        const remaining_mask = expected_masks[sequence] & ~terminal_mask;
        try std.testing.expectEqual(
            retained_receipt.proposal.request_epoch,
            retained_wave.request_epoch,
        );
        try std.testing.expectEqual(@as(u8, 0), retained_wave.reclaimed_mask);
        try std.testing.expectEqual(
            LeaseReclaimPolicy.retain_until_teardown,
            retained_wave.reclaim_policy,
        );
        try std.testing.expectEqualDeep(
            retained_receipt.proposal_sha256,
            retained_wave.proposal_sha256,
        );
        try std.testing.expectEqualDeep(
            retained_receipt.commit_sha256,
            retained_wave.commit_sha256,
        );
        try std.testing.expectEqual(
            retained_receipt.proposal.tree.tree_key,
            retained_wave.tree.tree_key,
        );
        try std.testing.expectEqual(
            retained_receipt.proposal.tree.identity_generation,
            retained_wave.tree.identity_generation,
        );
        try std.testing.expectEqual(
            retained_receipt.proposal.tree.current.kv_bytes,
            retained_wave.tree.current.kv_bytes,
        );
        try std.testing.expectEqual(paged_lease_wave_observer_abi, wave.abi_version);
        try std.testing.expectEqual(
            immediate_receipt.proposal.request_epoch,
            wave.request_epoch,
        );
        try std.testing.expectEqual(@as(u64, @intCast(sequence)), wave.transaction_sequence);
        try std.testing.expectEqual(@as(u64, @intCast(sequence + 1)), wave.next_sequence);
        try std.testing.expectEqual(expected_masks[sequence], wave.published_live_mask);
        try std.testing.expectEqual(terminal_mask, wave.terminal_mask);
        try std.testing.expectEqual(remaining_mask, wave.remaining_live_mask);
        try std.testing.expectEqual(terminal_mask, wave.reclaimed_mask);
        try std.testing.expectEqual(LeaseReclaimPolicy.terminal_immediate, wave.reclaim_policy);
        try std.testing.expectEqualDeep(
            immediate_receipt.proposal_sha256,
            wave.proposal_sha256,
        );
        try std.testing.expectEqualDeep(
            immediate_receipt.commit_sha256,
            wave.commit_sha256,
        );
        try std.testing.expectEqual(
            paged_lease_token_txn.tree_commitment_abi,
            wave.tree.abi_version,
        );
        try std.testing.expectEqual(
            immediate_receipt.proposal.tree.tree_key,
            wave.tree.tree_key,
        );
        try std.testing.expectEqual(
            immediate_receipt.proposal.tree.identity_generation,
            wave.tree.identity_generation,
        );
        try std.testing.expectEqual(
            page_payload_bytes * (width - sequence - 1),
            wave.tree.current.kv_bytes,
        );
        try std.testing.expectEqual(
            immediate_envelope.parent_claim.kv_bytes +
                page_payload_bytes * (width - sequence - 1),
            wave.bank.used.kv_bytes,
        );
        try std.testing.expectEqual(@as(usize, 1), wave.bank.active_lease_trees);
        try std.testing.expectEqual(@as(usize, 1), wave.bank.committed_receipts);
        for (0..sequence) |lane| {
            try std.testing.expectEqual(
                leased_paged_kv.LeaseLifecycle.terminal_retained,
                retained_receipt.proposal.resources[lane].lifecycle,
            );
            try std.testing.expectEqual(
                leased_paged_kv.LeaseLifecycle.reclaimed,
                immediate_receipt.proposal.resources[lane].lifecycle,
            );
            try std.testing.expectEqual(
                @as(u32, 1),
                retained_receipt.proposal.resources[lane].allocation_set.count,
            );
            try std.testing.expect(
                retained_receipt.proposal.resources[lane].has_binding_summary,
            );
            try std.testing.expectEqual(
                @as(u32, 0),
                immediate_receipt.proposal.resources[lane].allocation_set.count,
            );
            try std.testing.expect(
                !immediate_receipt.proposal.resources[lane].has_binding_summary,
            );
            try std.testing.expectEqualDeep(
                leased_paged_kv.BindingSummaryV1{
                    .count = 0,
                    .payload_bytes = 0,
                    .digest = [_]u8{0} ** 32,
                },
                immediate_receipt.proposal.resources[lane].binding_summary,
            );
        }
        const terminal = immediate_receipt.terminal_seals[sequence] orelse
            return error.TestExpectedEqual;
        const terminal_resource =
            immediate_receipt.proposal.resources[sequence];
        try std.testing.expectEqual(
            @as(u64, @intCast(sequence)),
            terminal.transaction_sequence,
        );
        try std.testing.expectEqual(@as(u32, 7), terminal.terminal_token);
        try std.testing.expect(terminal_resource.has_terminal_generation);
        try std.testing.expectEqual(
            terminal_resource.terminal_generation,
            terminal.generation,
        );
        try std.testing.expectEqualDeep(
            terminal_resource.binding_summary,
            terminal.bindings,
        );
    }

    const immediate_snapshot = try immediate_bank.snapshotV3();
    try std.testing.expect(immediate_snapshot.used.isZero());
    try std.testing.expectEqual(@as(usize, 0), immediate_snapshot.active_lease_trees);
    try std.testing.expectEqual(@as(usize, 0), immediate_snapshot.active_lease_nodes);
    try std.testing.expectEqual(@as(usize, 0), immediate_snapshot.committed_receipts);
    try std.testing.expectEqual(@as(u64, width), immediate_snapshot.lease_reclaim_commits);
    try std.testing.expectEqual(@as(u64, 1), immediate_snapshot.lease_tree_closes);
    try std.testing.expectEqual(@as(u64, 1), immediate_snapshot.releases);
}

test "PagedLeaseTokenTxn distinguishes retryable wave zero from committed interruption" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var model = try testPreparedModelLayers(68, 2);
    defer model.deinit();
    const prompts = [width][1]u32{ .{0}, .{1}, .{2}, .{3} };
    const forced = [width][3]u32{
        .{ 7, 1, 1 },
        .{ 1, 1, 1 },
        .{ 1, 1, 1 },
        .{ 1, 1, 1 },
    };
    var requests = testRequests(&prompts);
    for (&requests, 0..) |*request, lane| {
        request.max_new_tokens = 3;
        request.eos_token = 7;
        request.forced_tokens = &forced[lane];
    }

    for (0..2) |rejected_sequence| {
        var sink: TestPagedLeaseTxnSink = .{
            .reject_sequence = rejected_sequence,
        };
        const options: Options = .{
            .num_threads = 2,
            .kv_cache_mode = .paged16_required,
            .paged_admission_mode = .lease_tree_required,
            .lease_reclaim_policy = .terminal_immediate,
            .kv_capacity_positions = paged_kv.page_positions + 1,
            .paged_lease_token_txn_publication = .{
                .request_epoch = 0x5032_434c_4552_0001 + rejected_sequence,
                .sink = sink.sink(),
            },
        };
        const envelope = try deriveResourceAdmissionEnvelope(
            model,
            requests,
            options,
        );
        try std.testing.expect(envelope.required_lease_nodes <= 64);
        var slots = [_]resource_bank.Slot{.{}} ** 1;
        var roots = [_]resource_bank.LeaseTreeRootSlot{.{}} ** 1;
        var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 64;
        const node_count: usize = @intCast(envelope.required_lease_nodes);
        var bank = try resource_bank.Bank.initWithLeaseTree(
            &slots,
            &roots,
            nodes[0..node_count],
            .{
                .host_bytes = try envelope.bounded_peak_claim.hostBytes(),
                .kv_bytes = envelope.bounded_peak_claim.kv_bytes,
                .queue_slots = width,
            },
            0x5032_434c_4552_1001 + rejected_sequence,
        );
        var telemetry: Telemetry = .{};
        var run_options = options;
        run_options.request_resource_bank = &bank;
        run_options.telemetry = &telemetry;
        if (rejected_sequence == 0) {
            try std.testing.expectError(
                generate_api.GenerateError.TokenTransactionRejected,
                generate(
                    std.testing.allocator,
                    model,
                    requests,
                    run_options,
                ),
            );
        } else {
            try std.testing.expectError(
                generate_api.GenerateError.PostPublicationGenerationInterrupted,
                generate(
                    std.testing.allocator,
                    model,
                    requests,
                    run_options,
                ),
            );
        }
        try std.testing.expectEqual(rejected_sequence + 1, sink.prepare_count);
        try std.testing.expectEqual(rejected_sequence, sink.commit_count);
        try std.testing.expectEqual(@as(usize, 0), sink.abort_count);
        try std.testing.expectEqual(rejected_sequence, telemetry.token_txn_commits);
        try std.testing.expectEqual(@as(usize, 1), telemetry.token_txn_aborts);
        try std.testing.expectEqual(@as(usize, 1), telemetry.token_txn_sink_rejects);
        try std.testing.expectEqual(
            rejected_sequence,
            telemetry.paged_lease_reclaimed_lanes,
        );
        const snapshot = try bank.snapshotV3();
        try std.testing.expect(snapshot.used.isZero());
        try std.testing.expectEqual(@as(usize, 0), snapshot.active_lease_trees);
        try std.testing.expectEqual(@as(usize, 0), snapshot.active_lease_nodes);
        try std.testing.expectEqual(@as(usize, 0), snapshot.committed_receipts);
        try std.testing.expectEqual(@as(u64, width), snapshot.lease_reclaim_commits);
        try std.testing.expectEqual(@as(u64, 1), snapshot.lease_tree_closes);
        try std.testing.expectEqual(@as(u64, 1), snapshot.releases);
    }
}

test "PagedLeaseTokenTxn page-boundary exact cap passes and one byte under stops" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var model = try testPreparedModelLayers(68, 2);
    defer model.deinit();
    var prompt_storage: [width][paged_kv.page_positions]u32 = undefined;
    const forced = [width][2]u32{
        .{ 1, 7 },
        .{ 1, 7 },
        .{ 1, 7 },
        .{ 1, 7 },
    };
    var requests: [width]Request = undefined;
    for (&requests, 0..) |*request, lane| {
        for (&prompt_storage[lane]) |*token| token.* = @intCast(lane);
        request.* = .{
            .prompt = &prompt_storage[lane],
            .max_new_tokens = 2,
            .eos_token = 7,
            .forced_tokens = &forced[lane],
            .seed = lane + 1,
        };
    }

    for (0..2) |one_byte_under| {
        var sink: TestPagedLeaseTxnSink = .{};
        var admission_observer: TestPagedLeaseAdmissionObserver = .{};
        const options: Options = .{
            .num_threads = 2,
            .kv_cache_mode = .paged16_required,
            .paged_admission_mode = .lease_tree_required,
            .lease_reclaim_policy = .terminal_immediate,
            .kv_capacity_positions = paged_kv.page_positions + 1,
            .paged_lease_token_txn_publication = .{
                .request_epoch = 0x5032_434c_4341_0001 + one_byte_under,
                .sink = sink.sink(),
            },
            .paged_lease_admission_observer = admission_observer.observer(),
        };
        const envelope = try deriveResourceAdmissionEnvelope(
            model,
            requests,
            options,
        );
        const lane_ledger = try paged_kv.deriveCapacityLedger(
            model.config.num_layers,
            model.config.num_kv_heads * model.config.head_dim,
            paged_kv.page_positions + 1,
        );
        try std.testing.expectEqual(
            @as(u64, @intCast(lane_ledger.page_payload_bytes * width * 2)),
            envelope.bounded_peak_payload_bytes,
        );
        try std.testing.expectEqual(@as(u32, width + width * 2), envelope.required_lease_nodes);
        var slots = [_]resource_bank.Slot{.{}} ** 1;
        var roots = [_]resource_bank.LeaseTreeRootSlot{.{}} ** 1;
        var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 16;
        const node_count: usize = @intCast(envelope.required_lease_nodes);
        var bank = try resource_bank.Bank.initWithLeaseTree(
            &slots,
            &roots,
            nodes[0..node_count],
            .{
                .host_bytes = try envelope.bounded_peak_claim.hostBytes(),
                .kv_bytes = envelope.bounded_peak_claim.kv_bytes -
                    one_byte_under,
                .queue_slots = width,
            },
            0x5032_434c_4341_1001 + one_byte_under,
        );
        var telemetry: Telemetry = .{};
        var run_options = options;
        run_options.request_resource_bank = &bank;
        run_options.telemetry = &telemetry;
        if (one_byte_under == 0) {
            var result = try generate(
                std.testing.allocator,
                model,
                requests,
                run_options,
            );
            defer result.deinit();
            for (0..width) |lane|
                try std.testing.expectEqualSlices(
                    u32,
                    &forced[lane],
                    result.tokens(lane),
                );
            try std.testing.expectEqual(@as(usize, 2), sink.commit_count);
            try std.testing.expectEqual(@as(usize, width), telemetry.paged_lease_reclaimed_lanes);
            try std.testing.expectEqual(@as(usize, 0), admission_observer.count);
        } else {
            try std.testing.expectError(
                generate_api.GenerateError.PostPublicationGenerationInterrupted,
                generate(
                    std.testing.allocator,
                    model,
                    requests,
                    run_options,
                ),
            );
            try std.testing.expectEqual(@as(usize, 1), sink.prepare_count);
            try std.testing.expectEqual(@as(usize, 1), sink.commit_count);
            try std.testing.expectEqual(@as(usize, 0), telemetry.paged_lease_reclaimed_lanes);
            try std.testing.expectEqual(@as(usize, 1), admission_observer.count);
            const evidence = admission_observer.evidence;
            try std.testing.expectEqual(
                paged_lease_admission_observer_abi,
                evidence.abi_version,
            );
            try std.testing.expectEqual(
                options.paged_lease_token_txn_publication.?.request_epoch,
                evidence.request_epoch,
            );
            try std.testing.expectEqual(@as(u64, 1), evidence.transaction_sequence);
            try std.testing.expectEqual(@as(u32, 3), evidence.failed_lane);
            try std.testing.expectEqual(@as(u8, 0b1111), evidence.active_mask);
            try std.testing.expectEqual(
                PagedLeaseAdmissionFailureKind.capacity_exceeded,
                evidence.failure,
            );
            try std.testing.expectEqual(
                @as(u64, @intCast(lane_ledger.page_payload_bytes * 7)),
                evidence.tree.current.kv_bytes,
            );
            try std.testing.expectEqual(@as(u32, width + 7), evidence.tree.active_nodes);
            const expected_allocated = [_]usize{ 2, 2, 2, 1 };
            const expected_reusable = [_]usize{ 1, 1, 1, 0 };
            for (evidence.lanes, 0..) |lane_state, lane| {
                try std.testing.expectEqual(
                    @as(u64, paged_kv.page_positions),
                    lane_state.root.committed_len,
                );
                try std.testing.expectEqual(expected_allocated[lane], lane_state.allocation.allocated_pages);
                try std.testing.expectEqual(@as(usize, 1), lane_state.allocation.committed_pages);
                try std.testing.expectEqual(@as(usize, 0), lane_state.allocation.provisional_pages);
                try std.testing.expectEqual(expected_reusable[lane], lane_state.allocation.reusable_pages);
                try std.testing.expectEqual(leased_paged_kv.LeaseLifecycle.live, lane_state.lifecycle);
            }
            try std.testing.expectEqual(
                envelope.parent_claim.kv_bytes +
                    @as(u64, @intCast(lane_ledger.page_payload_bytes * 7)),
                evidence.bank.used.kv_bytes,
            );
            try std.testing.expectEqual(@as(u64, 1), evidence.bank.rejected_lease_capacity);
            try std.testing.expectEqual(@as(u64, 0), evidence.bank.rejected_lease_nodes);
            try std.testing.expectEqual(@as(usize, 7), evidence.bank.live_allocations);
        }
        const snapshot = try bank.snapshotV3();
        try std.testing.expect(snapshot.used.isZero());
        try std.testing.expectEqual(@as(usize, 0), snapshot.active_lease_trees);
        try std.testing.expectEqual(@as(usize, 0), snapshot.active_lease_nodes);
        try std.testing.expectEqual(@as(usize, 0), snapshot.committed_receipts);
        try std.testing.expectEqual(
            @as(u64, @intCast(one_byte_under)),
            snapshot.rejected_lease_capacity,
        );
        try std.testing.expectEqual(@as(u64, width), snapshot.lease_reclaim_commits);
        try std.testing.expectEqual(@as(u64, 1), snapshot.lease_tree_closes);
        try std.testing.expectEqual(@as(u64, 1), snapshot.releases);
    }
}

test "resident child one-byte-under cap rejects before page allocation" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var model = try testPreparedModelLayers(68, 2);
    defer model.deinit();
    const prompts = [width][1]u32{ .{0}, .{1}, .{2}, .{3} };
    const requests = testRequests(&prompts);
    var sink: TestPagedElasticTxnSink = .{};
    const options: Options = .{
        .num_threads = 2,
        .kv_cache_mode = .paged16_required,
        .paged_admission_mode = .resident_child_required,
        .kv_capacity_positions = 17,
        .paged_elastic_token_txn_publication = .{
            .request_epoch = 0x5032_4355_4e44_0001,
            .sink = sink.sink(),
        },
    };
    const envelope = try deriveResourceAdmissionEnvelope(
        model,
        requests,
        options,
    );
    var slots: [width]resource_bank.Slot = undefined;
    var child_slots: [width]resource_bank.ChildSlot = undefined;
    var bank = try resource_bank.Bank.initWithChildSlots(
        &slots,
        &child_slots,
        .{
            .host_bytes = (try envelope.bounded_peak_claim.hostBytes()) - 1,
            .kv_bytes = envelope.bounded_peak_claim.kv_bytes - 1,
            .logits_bytes = envelope.parent_claim.logits_bytes,
            .queue_slots = width,
        },
        0x5032_4355_4e44_0002,
    );
    var telemetry: Telemetry = .{};
    try std.testing.expectError(
        generate_api.GenerateError.ResourceBudgetExceeded,
        generate(
            std.testing.allocator,
            model,
            requests,
            .{
                .num_threads = 2,
                .kv_cache_mode = .paged16_required,
                .paged_admission_mode = .resident_child_required,
                .kv_capacity_positions = 17,
                .request_resource_bank = &bank,
                .paged_elastic_token_txn_publication = .{
                    .request_epoch = 0x5032_4355_4e44_0001,
                    .sink = sink.sink(),
                },
                .telemetry = &telemetry,
            },
        ),
    );
    const snapshot = try bank.snapshotV2();
    try std.testing.expect(snapshot.used.isZero());
    try std.testing.expectEqual(@as(u64, 1), snapshot.child_opens);
    try std.testing.expectEqual(@as(u64, 0), snapshot.child_grows);
    try std.testing.expectEqual(@as(u64, 1), snapshot.rejected_child_capacity);
    try std.testing.expectEqual(@as(u64, 1), snapshot.child_closes);
    try std.testing.expectEqual(@as(u64, 1), snapshot.releases);
    try std.testing.expectEqual(@as(usize, 0), sink.prepare_count);
    try std.testing.expectEqual(@as(usize, 1), telemetry.paged_kv_child_capacity_rejects);
}

test "resident child aggregate growth stays charged through partial lane OOM" {
    const one_lane = try paged_kv.deriveCapacityLedger(1, 1, 1);
    const page_map_bytes = try std.math.mul(
        usize,
        width,
        one_lane.page_map_bytes,
    );
    const aggregate_payload_bytes = try std.math.mul(
        usize,
        width,
        one_lane.page_payload_bytes,
    );
    const logical_capacity_bytes = try std.math.add(
        usize,
        page_map_bytes,
        aggregate_payload_bytes,
    );
    try std.testing.expectEqual(
        try std.math.mul(usize, width, one_lane.allocation_capacity_bytes),
        logical_capacity_bytes,
    );

    const page_map_u64 = std.math.cast(u64, page_map_bytes) orelse
        return error.TestExpectedEqual;
    const aggregate_payload_u64 = std.math.cast(
        u64,
        aggregate_payload_bytes,
    ) orelse return error.TestExpectedEqual;
    const logical_capacity_u64 = std.math.cast(
        u64,
        logical_capacity_bytes,
    ) orelse return error.TestExpectedEqual;

    var slots: [width]resource_bank.Slot = undefined;
    var child_slots: [width]resource_bank.ChildSlot = undefined;
    var bank = try resource_bank.Bank.initWithChildSlots(
        &slots,
        &child_slots,
        .{
            .host_bytes = logical_capacity_u64,
            .kv_bytes = logical_capacity_u64,
            .queue_slots = width,
        },
        0x5032_434f_4f4d_0001,
    );
    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{},
    );

    {
        const receipt = try bank.commit(try bank.reserve(
            0x5032_434f_4f4d_0002,
            .{ .kv_bytes = page_map_u64, .queue_slots = width },
        ));
        defer bank.release(receipt) catch
            @panic("partial-OOM test parent receipt failed to release");

        var resident_child: ?resource_bank.ChildLease = try bank.openChild(
            receipt,
            0x5032_434f_4f4d_0003,
            .{ .kv_bytes = aggregate_payload_u64 },
            .{},
        );
        defer {
            const lease = resident_child orelse
                @panic("partial-OOM test lost resident child");
            bank.closeChild(lease) catch
                @panic("partial-OOM test resident child failed to close");
            resident_child = null;
        }

        var session: paged_elastic_token_txn.Session = .{};
        try session.init(
            &bank,
            receipt,
            resident_child.?,
            0x5032_434f_4f4d_0004,
            paged_resident_decode_abi,
            logical_capacity_u64,
        );
        defer session.close() catch
            @panic("partial-OOM test session failed to close");

        var caches: [width]RuntimeKvCache = undefined;
        var initialized_caches: usize = 0;
        defer for (caches[0..initialized_caches]) |*cache| cache.deinit();
        for (&caches) |*cache| {
            cache.* = try RuntimeKvCache.init(
                failing_allocator.allocator(),
                .paged16_required,
                1,
                1,
                1,
            );
            initialized_caches += 1;
        }

        // Permit two lane payload allocations, then fail lane 2. The Bank must
        // already hold the aggregate four-lane charge before lane 0 allocates.
        failing_allocator.fail_index = failing_allocator.alloc_index + 2;
        var resources: generate_api.RequestResourceTelemetry = .{};
        var telemetry: Telemetry = .{};
        try std.testing.expectError(
            generate_api.GenerateError.OutOfMemory,
            beginResidentKvMarks(
                &caches,
                [_]bool{true} ** width,
                &session,
                &resident_child,
                &resources,
                &telemetry,
            ),
        );
        try std.testing.expect(failing_allocator.has_induced_failure);
        try std.testing.expectEqualDeep(resident_child.?, session.child_lease);
        try std.testing.expectEqual(
            aggregate_payload_u64,
            session.child_lease.claim.kv_bytes,
        );

        const charged = try bank.snapshotV2();
        try std.testing.expectEqual(
            logical_capacity_u64,
            charged.used.kv_bytes,
        );
        try std.testing.expectEqual(
            logical_capacity_u64,
            charged.peak.kv_bytes,
        );
        try std.testing.expectEqual(@as(usize, 1), charged.active_child_leases);
        try std.testing.expectEqual(@as(u64, 1), charged.child_opens);
        try std.testing.expectEqual(@as(u64, 1), charged.child_grows);
        try std.testing.expectEqual(
            aggregate_payload_u64,
            resources.child_current_kv_bytes,
        );
        try std.testing.expectEqual(@as(usize, 1), resources.active_child_leases);
        try std.testing.expectEqual(
            aggregate_payload_bytes,
            telemetry.paged_kv_child_current_bytes,
        );
        try std.testing.expectEqual(
            aggregate_payload_bytes,
            telemetry.paged_kv_child_peak_bytes,
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            telemetry.paged_kv_child_growth_events,
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            telemetry.token_txn_provisional_aborts,
        );

        for (&caches, 0..) |*runtime_cache, lane| {
            const cache = runtime_cache.pagedPtr().?;
            const ledger = try cache.allocationCommitmentLedger();
            const expected_allocated: usize = @intFromBool(lane < 2);
            try std.testing.expectEqual(@as(usize, 0), cache.len);
            try std.testing.expectEqual(expected_allocated, ledger.allocated_pages);
            try std.testing.expectEqual(@as(usize, 0), ledger.committed_pages);
            try std.testing.expectEqual(@as(usize, 0), ledger.provisional_pages);
            try std.testing.expectEqual(expected_allocated, ledger.reusable_pages);
        }
    }

    const final = try bank.snapshotV2();
    try std.testing.expect(final.used.isZero());
    try std.testing.expectEqual(@as(usize, 0), final.active_child_leases);
    try std.testing.expectEqual(@as(u64, 1), final.child_opens);
    try std.testing.expectEqual(@as(u64, 1), final.child_grows);
    try std.testing.expectEqual(@as(u64, 1), final.child_closes);
    try std.testing.expectEqual(@as(u64, 1), final.releases);
    try std.testing.expectEqual(
        failing_allocator.allocated_bytes,
        failing_allocator.freed_bytes,
    );
    try std.testing.expectEqual(
        failing_allocator.allocations,
        failing_allocator.deallocations,
    );
}

test "PagedElasticTokenTxn corrupt ack at page boundary closes every charge" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var model = try testPreparedModelLayers(68, 2);
    defer model.deinit();
    var prompt_storage: [width][paged_kv.page_positions]u32 = undefined;
    var requests: [width]Request = undefined;
    for (&requests, 0..) |*request, lane| {
        for (&prompt_storage[lane]) |*token| token.* = @intCast(lane);
        request.* = .{
            .prompt = &prompt_storage[lane],
            .max_new_tokens = 2,
            .seed = lane + 1,
        };
    }

    var sink: TestPagedElasticTxnSink = .{ .corrupt_ack_sequence = 1 };
    const options: Options = .{
        .num_threads = 2,
        .kv_cache_mode = .paged16_required,
        .paged_admission_mode = .resident_child_required,
        .kv_capacity_positions = paged_kv.page_positions + 1,
        .paged_elastic_token_txn_publication = .{
            .request_epoch = 0x5032_4341_434b_0001,
            .sink = sink.sink(),
        },
    };
    const envelope = try deriveResourceAdmissionEnvelope(
        model,
        requests,
        options,
    );
    const one_lane = try paged_kv.deriveCapacityLedger(
        model.config.num_layers,
        model.config.num_kv_heads * model.config.head_dim,
        paged_kv.page_positions + 1,
    );
    const first_page_wave = try std.math.mul(
        usize,
        width,
        one_lane.page_payload_bytes,
    );
    const boundary_page_wave = try std.math.mul(usize, first_page_wave, 2);
    try std.testing.expectEqual(
        std.math.cast(u64, boundary_page_wave) orelse
            error.TestExpectedEqual,
        envelope.bounded_peak_payload_bytes,
    );
    try std.testing.expectEqual(
        std.math.cast(u64, width * one_lane.page_map_bytes) orelse
            error.TestExpectedEqual,
        envelope.page_map_bytes,
    );

    var slots: [width]resource_bank.Slot = undefined;
    var child_slots: [width]resource_bank.ChildSlot = undefined;
    var bank = try resource_bank.Bank.initWithChildSlots(
        &slots,
        &child_slots,
        .{
            .host_bytes = try envelope.bounded_peak_claim.hostBytes(),
            .kv_bytes = envelope.bounded_peak_claim.kv_bytes,
            .logits_bytes = envelope.parent_claim.logits_bytes,
            .queue_slots = width,
        },
        0x5032_4341_434b_0002,
    );
    var telemetry: Telemetry = .{};
    var resources: generate_api.RequestResourceTelemetry = .{};
    var run_options = options;
    run_options.request_resource_bank = &bank;
    run_options.resource_telemetry = &resources;
    run_options.telemetry = &telemetry;
    try std.testing.expectError(
        generate_api.GenerateError.TokenTransactionRejected,
        generate(
            std.testing.allocator,
            model,
            requests,
            run_options,
        ),
    );

    try std.testing.expectEqual(@as(usize, 2), sink.prepare_count);
    try std.testing.expectEqual(@as(usize, 1), sink.commit_count);
    try std.testing.expectEqual(@as(usize, 1), sink.abort_count);
    const first = sink.prepared[0];
    const boundary = sink.prepared[1];
    try std.testing.expectEqual(@as(u64, 0), first.transaction_sequence);
    try std.testing.expectEqual(@as(u64, 1), boundary.transaction_sequence);
    try std.testing.expectEqual(
        std.math.cast(u64, first_page_wave) orelse error.TestExpectedEqual,
        first.resident_payload_bytes,
    );
    try std.testing.expectEqual(
        envelope.bounded_peak_payload_bytes,
        boundary.resident_payload_bytes,
    );
    try std.testing.expect(
        boundary.child_lease.generation > first.child_lease.generation,
    );
    try std.testing.expectEqual(
        boundary.resident_payload_bytes,
        boundary.child_lease.claim.kv_bytes,
    );
    for (boundary.lanes) |lane| {
        try std.testing.expect(lane.has_kv_transition);
        try std.testing.expectEqual(@as(u64, 2), lane.allocated_pages);
        try std.testing.expectEqual(@as(u64, 1), lane.committed_pages);
        try std.testing.expectEqual(@as(u64, 1), lane.provisional_pages);
        try std.testing.expectEqual(@as(u64, 0), lane.reusable_pages);
        try std.testing.expect(lane.kv_transition.installs_new_page);
        try std.testing.expectEqual(@as(u64, 1), lane.kv_transition.logical_page);
        try std.testing.expectEqual(@as(u64, 16), lane.kv_transition.root_before_len);
        try std.testing.expectEqual(@as(u64, 17), lane.kv_transition.root_after_len);
        try std.testing.expectEqual(@as(u64, 1), lane.kv_transition.root_before_pages);
        try std.testing.expectEqual(@as(u64, 2), lane.kv_transition.root_after_pages);
    }

    try std.testing.expectEqual(@as(usize, 1), telemetry.token_txn_commits);
    try std.testing.expectEqual(@as(usize, 1), telemetry.token_txn_aborts);
    try std.testing.expectEqual(@as(usize, 0), telemetry.token_txn_provisional_aborts);
    try std.testing.expectEqual(@as(usize, 1), telemetry.token_txn_sink_rejects);
    try std.testing.expectEqual(
        boundary_page_wave,
        telemetry.paged_kv_child_current_bytes,
    );
    try std.testing.expectEqual(
        boundary_page_wave,
        telemetry.paged_kv_child_peak_bytes,
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        telemetry.paged_kv_child_growth_events,
    );

    const snapshot = try bank.snapshotV2();
    try std.testing.expect(snapshot.used.isZero());
    try std.testing.expectEqual(@as(usize, 0), snapshot.active_child_leases);
    try std.testing.expectEqual(@as(usize, 0), snapshot.committed_receipts);
    try std.testing.expectEqual(@as(u64, 1), snapshot.child_opens);
    try std.testing.expectEqual(@as(u64, 2), snapshot.child_grows);
    try std.testing.expectEqual(@as(u64, 0), snapshot.child_shrinks);
    try std.testing.expectEqual(@as(u64, 1), snapshot.child_closes);
    try std.testing.expectEqual(@as(u64, 1), snapshot.releases);
    try std.testing.expectEqual(
        envelope.bounded_peak_claim.kv_bytes,
        snapshot.peak.kv_bytes,
    );
    try std.testing.expectEqual(
        try envelope.bounded_peak_claim.hostBytes(),
        snapshot.peak_host_bytes,
    );
    try std.testing.expectEqual(@as(usize, 0), resources.active_child_leases);
    try std.testing.expectEqual(@as(usize, 0), resources.release_failures);
    try std.testing.expectEqual(@as(u64, 2), resources.child_grows);
    try std.testing.expectEqual(@as(u64, 1), resources.child_closes);
}

test "PagedTokenTxn B4 rejects later wave without publication or Bank leak" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var model = try testPreparedModelLayers(68, 2);
    defer model.deinit();
    const prompts = [width][1]u32{ .{0}, .{1}, .{2}, .{3} };
    var requests = testRequests(&prompts);
    for (&requests) |*request| request.max_new_tokens = 3;

    for (0..2) |case| {
        var sink: TestPagedTxnSink = .{};
        if (case == 0)
            sink.reject_sequence = 1
        else
            sink.corrupt_ack_sequence = 1;
        const options: Options = .{
            .num_threads = 2,
            .kv_cache_mode = .paged16_required,
            .kv_capacity_positions = 17,
            .paged_token_txn_publication = .{
                .request_epoch = 0x5032_4252_454a_0001 + case,
                .sink = sink.sink(),
            },
        };
        const claim = try deriveResourceClaim(model, requests, options);
        var slots: [width]resource_bank.Slot = undefined;
        var bank = try resource_bank.Bank.init(
            &slots,
            .{
                .host_bytes = try claim.hostBytes(),
                .kv_bytes = claim.kv_bytes,
                .logits_bytes = claim.logits_bytes,
                .queue_slots = width,
            },
            0x5032_4252_454a_1001 + case,
        );
        var telemetry: Telemetry = .{};
        try std.testing.expectError(
            generate_api.GenerateError.TokenTransactionRejected,
            generate(
                std.testing.allocator,
                model,
                requests,
                .{
                    .num_threads = 2,
                    .kv_cache_mode = .paged16_required,
                    .kv_capacity_positions = 17,
                    .request_resource_bank = &bank,
                    .paged_token_txn_publication = .{
                        .request_epoch = 0x5032_4252_454a_0001 + case,
                        .sink = sink.sink(),
                    },
                    .telemetry = &telemetry,
                },
            ),
        );
        try std.testing.expectEqual(@as(usize, 2), sink.prepare_count);
        try std.testing.expectEqual(@as(usize, 1), sink.commit_count);
        try std.testing.expectEqual(
            @as(usize, @intFromBool(case == 1)),
            sink.abort_count,
        );
        try std.testing.expectEqual(@as(usize, 1), telemetry.token_txn_commits);
        try std.testing.expectEqual(@as(usize, 1), telemetry.token_txn_aborts);
        try std.testing.expectEqual(@as(usize, 1), telemetry.token_txn_sink_rejects);
        const snapshot = try bank.snapshot();
        try std.testing.expect(snapshot.used.isZero());
        try std.testing.expectEqual(@as(usize, 0), snapshot.active_reservations);
        try std.testing.expectEqual(@as(usize, 0), snapshot.committed_receipts);
        try std.testing.expectEqual(@as(u64, 1), snapshot.releases);
    }
}

test "TokenTxn B4 sink rejection rolls back a provisional KV wave" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    // Two layers ensure the rejected second wave completed every provisional
    // layer row before TokenTxn rolls the shared logical cursor back.
    var model = try testPreparedModelLayers(68, 2);
    defer model.deinit();
    const prompts = [width][1]u32{ .{0}, .{1}, .{2}, .{3} };
    var requests = testRequests(&prompts);
    for (&requests) |*request| request.max_new_tokens = 3;
    const claim = try deriveResourceClaim(model, requests, .{ .num_threads = 2 });

    for (0..2) |case| {
        var sink: TestTxnSink = .{};
        if (case == 0)
            sink.reject_sequence = 1
        else
            sink.corrupt_ack_sequence = 1;
        var slots: [width]resource_bank.Slot = undefined;
        var bank = try resource_bank.Bank.init(
            &slots,
            .{
                .host_bytes = try claim.hostBytes(),
                .logits_bytes = claim.logits_bytes,
                .queue_slots = width,
            },
            0x5458_4e52_454a_0001 + case,
        );
        var telemetry: Telemetry = .{};
        try std.testing.expectError(
            generate_api.GenerateError.TokenTransactionRejected,
            generate(
                std.testing.allocator,
                model,
                requests,
                .{
                    .num_threads = 2,
                    .request_resource_bank = &bank,
                    .token_txn_publication = .{
                        .request_epoch = 0x5458_4e46_4149_4c01 + case,
                        .sink = sink.sink(),
                    },
                    .telemetry = &telemetry,
                },
            ),
        );

        try std.testing.expectEqual(@as(usize, 2), sink.prepare_count);
        try std.testing.expectEqual(@as(usize, 1), sink.commit_count);
        try std.testing.expectEqual(@as(usize, case), sink.abort_count);
        try std.testing.expectEqual(@as(u64, 0), sink.committed[0].proposal.transaction_sequence);
        try std.testing.expectEqual(@as(u64, 1), sink.prepared[1].transaction_sequence);
        try std.testing.expectEqual(@as(u8, 0b1111), sink.prepared[1].live_mask);
        for (sink.prepared[1].lanes) |lane| {
            try std.testing.expect(lane.has_kv_transition);
            try std.testing.expectEqual(@as(u64, 1), lane.output_before);
            try std.testing.expectEqual(@as(u64, 1), lane.kv_before);
            try std.testing.expectEqual(@as(u64, 2), lane.kv_after);
        }
        try std.testing.expectEqual(@as(usize, 1), telemetry.token_txn_commits);
        try std.testing.expectEqual(@as(usize, width), telemetry.token_txn_lane_commits);
        try std.testing.expectEqual(@as(usize, 1), telemetry.token_txn_first_token_commits);
        try std.testing.expectEqual(@as(usize, 0), telemetry.token_txn_kv_row_commits);
        try std.testing.expectEqual(@as(usize, 1), telemetry.token_txn_aborts);
        try std.testing.expectEqual(@as(usize, 0), telemetry.token_txn_provisional_aborts);
        try std.testing.expectEqual(@as(usize, 1), telemetry.token_txn_sink_rejects);
        try std.testing.expectEqual(@as(u64, 0), telemetry.token_txn_last_sequence);

        const snapshot = try bank.snapshot();
        try std.testing.expect(snapshot.used.isZero());
        try std.testing.expectEqual(@as(usize, 0), snapshot.active_reservations);
        try std.testing.expectEqual(@as(usize, 0), snapshot.committed_receipts);
        try std.testing.expectEqual(@as(u64, 1), snapshot.releases);
    }
}

test "TokenTxn B4 freezes EOS-retired lanes and preserves forced RNG state" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var model = try testPreparedModel(68);
    defer model.deinit();
    const prompts = [width][1]u32{ .{0}, .{1}, .{2}, .{3} };
    const forced = [width][width]u32{
        .{ 7, 1, 1, 1 },
        .{ 1, 7, 1, 1 },
        .{ 1, 1, 7, 1 },
        .{ 1, 1, 1, 7 },
    };
    var requests = testRequests(&prompts);
    for (&requests, 0..) |*request, lane| {
        request.max_new_tokens = width;
        request.eos_token = 7;
        request.forced_tokens = &forced[lane];
    }
    const claim = try deriveResourceClaim(model, requests, .{ .num_threads = 2 });

    var legacy_slots: [width]resource_bank.Slot = undefined;
    var legacy_bank = try resource_bank.Bank.init(
        &legacy_slots,
        .{
            .host_bytes = try claim.hostBytes(),
            .logits_bytes = claim.logits_bytes,
            .queue_slots = width,
        },
        0x5458_4e45_4f53_0001,
    );
    var legacy_telemetry: Telemetry = .{};
    var legacy = try generate(
        std.testing.allocator,
        model,
        requests,
        .{
            .num_threads = 2,
            .request_resource_bank = &legacy_bank,
            .telemetry = &legacy_telemetry,
        },
    );
    defer legacy.deinit();

    var sink: TestTxnSink = .{};
    var strict_slots: [width]resource_bank.Slot = undefined;
    var strict_bank = try resource_bank.Bank.init(
        &strict_slots,
        .{
            .host_bytes = try claim.hostBytes(),
            .logits_bytes = claim.logits_bytes,
            .queue_slots = width,
        },
        0x5458_4e45_4f53_0002,
    );
    var strict_telemetry: Telemetry = .{};
    var strict = try generate(
        std.testing.allocator,
        model,
        requests,
        .{
            .num_threads = 2,
            .request_resource_bank = &strict_bank,
            .token_txn_publication = .{
                .request_epoch = 0x5458_4e45_4f53_1001,
                .sink = sink.sink(),
            },
            .telemetry = &strict_telemetry,
        },
    );
    defer strict.deinit();

    const expected_masks = [_]u8{ 0b1111, 0b1110, 0b1100, 0b1000 };
    for (0..width) |lane| {
        try std.testing.expectEqualSlices(u32, legacy.tokens(lane), strict.tokens(lane));
        try std.testing.expectEqual(lane + 1, strict.lengths[lane]);
        try std.testing.expectEqual(@as(u32, 7), strict.tokens(lane)[lane]);
        try std.testing.expectEqual(@as(usize, 0), strict_telemetry.lane_states[lane].sampling_calls);
        try std.testing.expectEqual(
            legacy_telemetry.lane_states[lane].rng_state,
            strict_telemetry.lane_states[lane].rng_state,
        );
    }
    try std.testing.expectEqualDeep(
        legacy_telemetry.lane_states,
        strict_telemetry.lane_states,
    );
    try std.testing.expectEqual(@as(usize, width), sink.commit_count);
    for (sink.committed[0..sink.commit_count], 0..) |receipt, sequence| {
        try std.testing.expectEqual(expected_masks[sequence], receipt.proposal.live_mask);
        for (0..width) |lane| {
            const lane_bit = @as(u8, 1) << @intCast(lane);
            if (receipt.proposal.live_mask & lane_bit == 0) continue;
            try std.testing.expectEqual(
                lane == sequence,
                receipt.proposal.lanes[lane].terminal,
            );
        }
    }
    try std.testing.expectEqual(@as(usize, 6), strict_telemetry.token_txn_kv_row_commits);
    try std.testing.expectEqual(@as(usize, 10), strict_telemetry.token_txn_lane_commits);
    try std.testing.expect((try legacy_bank.snapshot()).used.isZero());
    try std.testing.expect((try strict_bank.snapshot()).used.isZero());
}

test "TokenTxn B4 rejects malformed or split publication before Bank mutation" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    const Observer = struct {
        fn observe(
            _: *anyopaque,
            _: *const generate_api.TokenPublicationEvidenceV1,
        ) generate_api.TokenPublicationObserverError!void {}
    };
    var model = try testPreparedModel(68);
    defer model.deinit();
    const prompts = [width][1]u32{ .{0}, .{1}, .{2}, .{3} };
    const requests = testRequests(&prompts);
    const claim = try deriveResourceClaim(model, requests, .{ .num_threads = 2 });
    var slots: [width]resource_bank.Slot = undefined;
    var bank = try resource_bank.Bank.init(
        &slots,
        .{
            .host_bytes = try claim.hostBytes(),
            .logits_bytes = claim.logits_bytes,
            .queue_slots = width,
        },
        0x5458_4e50_5245_0001,
    );
    const initial = try bank.snapshot();
    var sink: TestTxnSink = .{};
    var dummy_context: u8 = 0;

    for (0..3) |case| {
        var publication_sink = sink.sink();
        var epoch: u64 = 1;
        var observer: ?generate_api.TokenPublicationObserver = null;
        switch (case) {
            0 => epoch = 0,
            1 => publication_sink.abi_version +%= 1,
            2 => observer = .{
                .context = &dummy_context,
                .observe = Observer.observe,
            },
            else => unreachable,
        }
        try std.testing.expectError(
            generate_api.GenerateError.TokenTransactionRejected,
            generate(
                std.testing.allocator,
                model,
                requests,
                .{
                    .num_threads = 2,
                    .request_resource_bank = &bank,
                    .token_publication_observer = observer,
                    .token_txn_publication = .{
                        .request_epoch = epoch,
                        .sink = publication_sink,
                    },
                },
            ),
        );
        try std.testing.expectEqualDeep(initial, try bank.snapshot());
        try std.testing.expectEqual(@as(usize, 0), sink.prepare_count);
        try std.testing.expectEqual(@as(usize, 0), sink.commit_count);
        try std.testing.expectEqual(@as(usize, 0), sink.abort_count);
    }
}

test "TokenTxn B4 closes its session before receipt release on later OOM" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var model = try testPreparedModel(68);
    defer model.deinit();
    const prompts = [width][1]u32{ .{0}, .{1}, .{2}, .{3} };
    const requests = testRequests(&prompts);
    const claim = try deriveResourceClaim(model, requests, .{ .num_threads = 2 });
    var slots: [width]resource_bank.Slot = undefined;
    var bank = try resource_bank.Bank.init(
        &slots,
        .{
            .host_bytes = try claim.hostBytes(),
            .logits_bytes = claim.logits_bytes,
            .queue_slots = width,
        },
        0x5458_4e4f_4f4d_0001,
    );
    var sink: TestTxnSink = .{};
    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{},
    );
    failing_allocator.fail_index = failing_allocator.alloc_index;
    try std.testing.expectError(
        generate_api.GenerateError.OutOfMemory,
        generate(
            failing_allocator.allocator(),
            model,
            requests,
            .{
                .num_threads = 2,
                .request_resource_bank = &bank,
                .token_txn_publication = .{
                    .request_epoch = 0x5458_4e4f_4f4d_1001,
                    .sink = sink.sink(),
                },
            },
        ),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), sink.prepare_count);
    try std.testing.expectEqual(@as(usize, 0), sink.commit_count);
    const snapshot = try bank.snapshot();
    try std.testing.expect(snapshot.used.isZero());
    try std.testing.expectEqual(@as(usize, 0), snapshot.active_reservations);
    try std.testing.expectEqual(@as(usize, 0), snapshot.committed_receipts);
    try std.testing.expectEqual(@as(u64, 1), snapshot.releases);
}

test "TokenTxn B4 fences the receipt before a hostile resource observer" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var model = try testPreparedModel(68);
    defer model.deinit();
    const prompts = [width][1]u32{ .{0}, .{1}, .{2}, .{3} };
    const requests = testRequests(&prompts);
    const claim = try deriveResourceClaim(model, requests, .{ .num_threads = 2 });
    var slots: [width]resource_bank.Slot = undefined;
    var bank = try resource_bank.Bank.init(
        &slots,
        .{
            .host_bytes = try claim.hostBytes(),
            .logits_bytes = claim.logits_bytes,
            .queue_slots = width,
        },
        0x5458_4e46_454e_0001,
    );
    var sink: TestTxnSink = .{};
    var attacker: SessionStealObserver = .{
        .bank = &bank,
        .attempted_epoch = 0x5458_4e46_454e_2001,
    };
    try std.testing.expectError(
        generate_api.GenerateError.ResourceCommitObserverRejected,
        generate(
            std.testing.allocator,
            model,
            requests,
            .{
                .num_threads = 2,
                .request_resource_bank = &bank,
                .resource_commit_observer = attacker.observer(),
                .token_txn_publication = .{
                    .request_epoch = 0x5458_4e46_454e_1001,
                    .sink = sink.sink(),
                },
            },
        ),
    );
    try std.testing.expect(attacker.called);
    try std.testing.expect(attacker.rejected_by_fence);
    try std.testing.expect(!attacker.stole_session);
    try std.testing.expect(!attacker.attacker.initialized);
    try std.testing.expectEqual(@as(usize, 0), sink.prepare_count);
    try std.testing.expectEqual(@as(usize, 0), sink.commit_count);
    const snapshot = try bank.snapshot();
    try std.testing.expect(snapshot.used.isZero());
    try std.testing.expectEqual(@as(usize, 0), snapshot.committed_receipts);
    try std.testing.expectEqual(@as(u64, 1), snapshot.releases);
}

test "TokenTxn terminal state hash enqueue failure stays pre-publication" {
    if (comptime builtin.single_threaded) return error.SkipZigTest;

    const prompts = [width][1]u32{ .{0}, .{1}, .{2}, .{3} };
    const requests = testRequests(&prompts);
    var caches: [width]kv.KVCache = undefined;
    var initialized: usize = 0;
    defer for (caches[0..initialized]) |*cache| cache.deinit();
    for (&caches) |*cache| {
        cache.* = try kv.KVCache.init(std.testing.allocator, 1, 2, 1);
        initialized += 1;
        _ = try cache.appendRow(0, &.{ 1, 2 }, &.{ 3, 4 });
        cache.commit();
    }

    var journals = [_][1]u32{.{0}} ** width;
    var result: Result = .{
        .allocator = std.testing.allocator,
        .storage = undefined,
        .lengths = [_]usize{0} ** width,
    };
    for (&result.storage, 0..) |*storage, lane|
        storage.* = &journals[lane];
    var prngs: [width]std.Random.DefaultPrng = undefined;
    var staged = [_]?StagedToken{null} ** width;
    for (0..width) |lane| {
        prngs[lane] = std.Random.DefaultPrng.init(lane + 1);
        staged[lane] = .{
            .token_id = @intCast(lane + 11),
            .rng_after = prngs[lane].s,
            .sampling_calls_after = 1,
            .terminal = true,
        };
    }
    var destination =
        [_]generate_api.GenerationStateTelemetry{.{}} ** width;
    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{},
    );
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = failing_allocator.allocator(),
        .n_jobs = 1,
    });
    defer pool.deinit();
    failing_allocator.fail_index = failing_allocator.alloc_index + 1;

    try std.testing.expectError(
        generate_api.GenerateError.OutOfMemory,
        prepareTerminalLaneStatesParallel(
            &pool,
            requests,
            &caches,
            &result,
            [_]bool{true} ** width,
            &staged,
            [_]usize{0} ** width,
            &prngs,
            &destination,
        ),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expectEqual([_]usize{0} ** width, result.lengths);
    for (&caches, 0..) |*cache, lane| {
        try std.testing.expectEqual(@as(usize, 1), cache.len);
        try std.testing.expectEqual(
            std.Random.DefaultPrng.init(lane + 1).s,
            prngs[lane].s,
        );
    }
}

test "single-epoch Pair down B4 matches split state through heterogeneous retirement" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var model = try testPreparedModel(68);
    defer model.deinit();
    const prompts = [width][1]u32{ .{0}, .{1}, .{2}, .{3} };
    var requests = testRequests(&prompts);
    for (&requests, 0..) |*request, lane|
        request.max_new_tokens = width - lane;

    const split_options: Options = .{
        .num_threads = 2,
        .pair_down_mode = .split_control,
    };
    const wave_options: Options = .{
        .num_threads = 2,
        .pair_down_mode = .single_epoch_required,
    };
    const split_claim = try deriveResourceClaim(model, requests, split_options);
    const wave_claim = try deriveResourceClaim(model, requests, wave_options);
    try std.testing.expectEqual(split_claim, wave_claim);

    var split_slots: [width]resource_bank.Slot = undefined;
    var split_bank = try resource_bank.Bank.init(
        &split_slots,
        .{
            .host_bytes = try split_claim.hostBytes(),
            .logits_bytes = split_claim.logits_bytes,
            .queue_slots = width,
        },
        0x5350_4c49_545f_0001,
    );
    var split_telemetry: Telemetry = .{};
    var split_resource: generate_api.RequestResourceTelemetry = .{};
    var split = try generate(
        std.testing.allocator,
        model,
        requests,
        .{
            .num_threads = 2,
            .request_resource_bank = &split_bank,
            .resource_telemetry = &split_resource,
            .pair_down_mode = .split_control,
            .telemetry = &split_telemetry,
        },
    );
    defer split.deinit();

    var wave_slots: [width]resource_bank.Slot = undefined;
    var wave_bank = try resource_bank.Bank.init(
        &wave_slots,
        .{
            .host_bytes = try wave_claim.hostBytes(),
            .logits_bytes = wave_claim.logits_bytes,
            .queue_slots = width,
        },
        0x5741_5645_5f42_3401,
    );
    var wave_telemetry: Telemetry = .{};
    var wave_resource: generate_api.RequestResourceTelemetry = .{};
    var wave = try generate(
        std.testing.allocator,
        model,
        requests,
        .{
            .num_threads = 2,
            .request_resource_bank = &wave_bank,
            .resource_telemetry = &wave_resource,
            .pair_down_mode = .single_epoch_required,
            .telemetry = &wave_telemetry,
        },
    );
    defer wave.deinit();

    for (0..width) |lane|
        try std.testing.expectEqualSlices(u32, split.tokens(lane), wave.tokens(lane));
    try std.testing.expect(std.meta.eql(
        split_telemetry.lane_states,
        wave_telemetry.lane_states,
    ));
    try std.testing.expect(split_resource.owner_key != wave_resource.owner_key);
    try std.testing.expectEqual(PairDownMode.split_control, split_telemetry.pair_down_mode);
    try std.testing.expectEqual(
        PairDownMode.single_epoch_required,
        wave_telemetry.pair_down_mode,
    );
    try std.testing.expectEqual(pair_down_wave_abi, wave_telemetry.pair_down_wave_abi_version);

    const token_graphs: usize = width;
    const split_epochs = token_graphs * 2;
    try std.testing.expectEqual(token_graphs, split_telemetry.layer_m4_graphs);
    try std.testing.expectEqual(split_epochs, split_telemetry.pair_down_split_worker_epochs);
    try std.testing.expectEqual(@as(usize, 0), split_telemetry.pair_down_single_epochs);
    try std.testing.expectEqual(@as(usize, 0), split_telemetry.pair_down_joins_elided);
    try std.testing.expectEqual(token_graphs, wave_telemetry.layer_m4_graphs);
    try std.testing.expectEqual(token_graphs, wave_telemetry.pair_down_single_epochs);
    try std.testing.expectEqual(split_epochs, wave_telemetry.pair_down_split_worker_epochs);
    try std.testing.expectEqual(token_graphs, wave_telemetry.pair_down_joins_elided);
    try std.testing.expectEqual(token_graphs * 2, wave_telemetry.pair_down_worker_tasks);
    try std.testing.expectEqual(token_graphs, wave_telemetry.pair_down_background_enqueues);
    try std.testing.expectEqual(@as(usize, 0), wave_telemetry.pair_down_enqueue_rejects);
    try std.testing.expect((try split_bank.snapshot()).used.isZero());
    try std.testing.expect((try wave_bank.snapshot()).used.isZero());
}

test "strict streaming B4 head matches materialized ties across a vocab tail" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var model = try testPreparedModel(68); // one full tile plus a rows4 tail
    defer model.deinit();
    const prompts = [width][1]u32{ .{0}, .{1}, .{2}, .{3} };
    const requests = testRequests(&prompts);
    const common_options: Options = .{ .num_threads = 2 };
    const materialized_claim = try deriveResourceClaim(
        model,
        requests,
        common_options,
    );
    const streaming_options: Options = .{
        .num_threads = 2,
        .greedy_head_mode = .streaming_required,
    };
    const streaming_claim = try deriveResourceClaim(
        model,
        requests,
        streaming_options,
    );
    const expected_reclaimed = try materializedLogitsBytes(68);
    try std.testing.expectEqual(
        @as(u64, @intCast(expected_reclaimed)),
        materialized_claim.logits_bytes,
    );
    try std.testing.expectEqual(@as(u64, 0), streaming_claim.logits_bytes);
    try std.testing.expectEqual(
        @as(u64, @intCast(expected_reclaimed)),
        (try materialized_claim.hostBytes()) -
            (try streaming_claim.hostBytes()),
    );

    var materialized_slots: [width]resource_bank.Slot = undefined;
    var materialized_bank = try resource_bank.Bank.init(
        &materialized_slots,
        .{
            .host_bytes = try materialized_claim.hostBytes(),
            .logits_bytes = materialized_claim.logits_bytes,
            .queue_slots = width,
        },
        0x4d34_4845_4144_0001,
    );
    var materialized_telemetry: Telemetry = .{};
    var materialized_resource: generate_api.RequestResourceTelemetry = .{};
    var materialized = try generate(
        std.testing.allocator,
        model,
        requests,
        .{
            .num_threads = 2,
            .request_resource_bank = &materialized_bank,
            .resource_telemetry = &materialized_resource,
            .telemetry = &materialized_telemetry,
        },
    );
    defer materialized.deinit();

    var streaming_slots: [width]resource_bank.Slot = undefined;
    var streaming_bank = try resource_bank.Bank.init(
        &streaming_slots,
        .{
            .host_bytes = try streaming_claim.hostBytes(),
            .logits_bytes = 0,
            .queue_slots = width,
        },
        0x5334_4845_4144_0001,
    );
    var streaming_telemetry: Telemetry = .{};
    var streaming_resource: generate_api.RequestResourceTelemetry = .{};
    var streamed = try generate(
        std.testing.allocator,
        model,
        requests,
        .{
            .num_threads = 2,
            .request_resource_bank = &streaming_bank,
            .resource_telemetry = &streaming_resource,
            .greedy_head_mode = .streaming_required,
            .telemetry = &streaming_telemetry,
        },
    );
    defer streamed.deinit();

    for (0..width) |lane| {
        try std.testing.expectEqualSlices(
            u32,
            materialized.tokens(lane),
            streamed.tokens(lane),
        );
        // Every one of 68 logits is exactly tied; the lowest token must win
        // across the 64-row task boundary and the final four-row tail.
        try std.testing.expectEqualSlices(u32, &.{0}, streamed.tokens(lane));
        try std.testing.expectEqual(
            materialized_telemetry.lane_states[lane].rng_state,
            streaming_telemetry.lane_states[lane].rng_state,
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            streaming_telemetry.lane_states[lane].sampling_calls,
        );
    }
    try std.testing.expectEqual(
        GreedyHeadMode.streaming_required,
        streaming_telemetry.greedy_head_mode,
    );
    try std.testing.expectEqual(
        greedy_head_abi,
        streaming_telemetry.greedy_head_abi_version,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        streaming_telemetry.lm_head_m4_dispatches,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        streaming_telemetry.streaming_greedy_head_m4_dispatches,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        streaming_telemetry.materialized_lm_head_m4_dispatches,
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        streaming_telemetry.streaming_greedy_head_tasks,
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        streaming_telemetry.streaming_greedy_head_shards,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        streaming_telemetry.streaming_greedy_head_tiles,
    );
    try std.testing.expectEqual(
        @as(usize, width * 2),
        streaming_telemetry.streaming_greedy_head_lane_candidates,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        streaming_telemetry.streaming_greedy_head_tile_scratch_bytes,
    );
    try std.testing.expectEqual(
        expected_reclaimed,
        streaming_telemetry.materialized_logits_reclaimed_bytes,
    );
    try std.testing.expectEqual(@as(u64, 0), streaming_resource.logits_bytes);
    try std.testing.expect((try materialized_bank.snapshot()).used.isZero());
    try std.testing.expect((try streaming_bank.snapshot()).used.isZero());
}

test "strict streaming B4 matches materialized heterogeneous retirement" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var model = try testPreparedModel(68);
    defer model.deinit();
    const prompts = [width][1]u32{ .{0}, .{1}, .{2}, .{3} };
    var requests = testRequests(&prompts);
    for (&requests, 0..) |*request, lane|
        request.max_new_tokens = lane + 1;

    const materialized_options: Options = .{ .num_threads = 2 };
    const materialized_claim = try deriveResourceClaim(
        model,
        requests,
        materialized_options,
    );
    var materialized_slots: [width]resource_bank.Slot = undefined;
    var materialized_bank = try resource_bank.Bank.init(
        &materialized_slots,
        .{
            .host_bytes = try materialized_claim.hostBytes(),
            .logits_bytes = materialized_claim.logits_bytes,
            .queue_slots = width,
        },
        0x4d34_5245_5449_5245,
    );
    var materialized_telemetry: Telemetry = .{};
    var materialized_resource: generate_api.RequestResourceTelemetry = .{};
    var materialized = try generate(
        std.testing.allocator,
        model,
        requests,
        .{
            .num_threads = 2,
            .request_resource_bank = &materialized_bank,
            .resource_telemetry = &materialized_resource,
            .telemetry = &materialized_telemetry,
        },
    );
    defer materialized.deinit();

    const streaming_options: Options = .{
        .num_threads = 2,
        .greedy_head_mode = .streaming_required,
    };
    const streaming_claim = try deriveResourceClaim(
        model,
        requests,
        streaming_options,
    );
    var streaming_slots: [width]resource_bank.Slot = undefined;
    var streaming_bank = try resource_bank.Bank.init(
        &streaming_slots,
        .{
            .host_bytes = try streaming_claim.hostBytes(),
            .logits_bytes = streaming_claim.logits_bytes,
            .queue_slots = width,
        },
        0x5334_5245_5449_5245,
    );
    var streaming_telemetry: Telemetry = .{};
    var streaming_resource: generate_api.RequestResourceTelemetry = .{};
    var streamed = try generate(
        std.testing.allocator,
        model,
        requests,
        .{
            .num_threads = 2,
            .request_resource_bank = &streaming_bank,
            .resource_telemetry = &streaming_resource,
            .greedy_head_mode = .streaming_required,
            .telemetry = &streaming_telemetry,
        },
    );
    defer streamed.deinit();

    for (0..width) |lane| {
        const expected_steps = lane + 1;
        try std.testing.expectEqualSlices(
            u32,
            materialized.tokens(lane),
            streamed.tokens(lane),
        );
        try std.testing.expectEqual(expected_steps, streamed.tokens(lane).len);
        for (streamed.tokens(lane)) |token|
            try std.testing.expectEqual(@as(u32, 0), token);

        const materialized_state = materialized_telemetry.lane_states[lane];
        const streaming_state = streaming_telemetry.lane_states[lane];
        try std.testing.expect(materialized_state.complete);
        try std.testing.expect(streaming_state.complete);
        try std.testing.expectEqual(
            expected_steps,
            materialized_state.kv_positions,
        );
        try std.testing.expectEqual(
            materialized_state.kv_positions,
            streaming_state.kv_positions,
        );
        try std.testing.expectEqualSlices(
            u8,
            &materialized_state.kv_sha256,
            &streaming_state.kv_sha256,
        );
        try std.testing.expectEqualSlices(
            u8,
            &materialized_state.output_sha256,
            &streaming_state.output_sha256,
        );
        try std.testing.expectEqual(
            expected_steps,
            materialized_state.published_tokens,
        );
        try std.testing.expectEqual(
            materialized_state.published_tokens,
            streaming_state.published_tokens,
        );
        try std.testing.expectEqual(
            expected_steps,
            materialized_state.sampling_calls,
        );
        try std.testing.expectEqual(
            materialized_state.sampling_calls,
            streaming_state.sampling_calls,
        );
        try std.testing.expectEqual(
            materialized_state.rng_state,
            streaming_state.rng_state,
        );
    }

    const expected_active_steps: usize = 1 + 2 + 3 + 4;
    const expected_graphs: usize = 4;
    const expected_padded_steps = expected_graphs * width -
        expected_active_steps;
    try std.testing.expectEqual(
        expected_active_steps,
        materialized_telemetry.active_lane_steps,
    );
    try std.testing.expectEqual(
        materialized_telemetry.active_lane_steps,
        streaming_telemetry.active_lane_steps,
    );
    try std.testing.expectEqual(
        expected_padded_steps,
        materialized_telemetry.padded_lane_steps,
    );
    try std.testing.expectEqual(
        materialized_telemetry.padded_lane_steps,
        streaming_telemetry.padded_lane_steps,
    );
    try std.testing.expectEqual(expected_graphs, materialized_telemetry.token_graphs);
    try std.testing.expectEqual(
        materialized_telemetry.token_graphs,
        streaming_telemetry.token_graphs,
    );
    try std.testing.expectEqual(
        expected_graphs,
        materialized_telemetry.lm_head_m4_dispatches,
    );
    try std.testing.expectEqual(
        materialized_telemetry.lm_head_m4_dispatches,
        streaming_telemetry.lm_head_m4_dispatches,
    );
    try std.testing.expectEqual(
        expected_graphs,
        materialized_telemetry.materialized_lm_head_m4_dispatches,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        streaming_telemetry.materialized_lm_head_m4_dispatches,
    );
    try std.testing.expectEqual(
        expected_graphs,
        streaming_telemetry.streaming_greedy_head_m4_dispatches,
    );
    try std.testing.expectEqual(
        expected_graphs * 2,
        streaming_telemetry.streaming_greedy_head_tasks,
    );
    try std.testing.expectEqual(
        expected_graphs * 2,
        streaming_telemetry.streaming_greedy_head_shards,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        streaming_telemetry.streaming_greedy_head_tiles,
    );
    try std.testing.expectEqual(
        expected_active_steps * 2,
        streaming_telemetry.streaming_greedy_head_lane_candidates,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        streaming_telemetry.streaming_greedy_head_tile_scratch_bytes,
    );
    try std.testing.expectEqual(@as(usize, 0), materialized_telemetry.fallbacks);
    try std.testing.expectEqual(@as(usize, 0), streaming_telemetry.fallbacks);

    const materialized_snapshot = try materialized_bank.snapshot();
    const streaming_snapshot = try streaming_bank.snapshot();
    try std.testing.expect(materialized_snapshot.used.isZero());
    try std.testing.expect(streaming_snapshot.used.isZero());
    try std.testing.expectEqual(@as(usize, 0), materialized_snapshot.active_reservations);
    try std.testing.expectEqual(@as(usize, 0), streaming_snapshot.active_reservations);
    try std.testing.expectEqual(@as(usize, 0), materialized_snapshot.committed_receipts);
    try std.testing.expectEqual(@as(usize, 0), streaming_snapshot.committed_receipts);
    try std.testing.expectEqual(@as(u64, 1), materialized_snapshot.releases);
    try std.testing.expectEqual(@as(u64, 1), streaming_snapshot.releases);
    try std.testing.expectEqual(@as(u64, 1), materialized_resource.releases);
    try std.testing.expectEqual(@as(u64, 1), streaming_resource.releases);
    try std.testing.expectEqual(@as(usize, 0), materialized_resource.release_failures);
    try std.testing.expectEqual(@as(usize, 0), streaming_resource.release_failures);
}

test "streaming B4 head matches non-tie materialized g8 and g16 logits" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    const in_f: usize = 16;
    const out_f: usize = 68; // retain a four-row tail after the 64-row tile
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var input_values: [width * in_f]f32 = undefined;
    for (0..width) |lane| {
        for (0..in_f) |col| {
            const positive: i32 = @intCast(
                ((lane + 1) * 17 + col * 5 + lane * col * 3) % 19,
            );
            input_values[lane * in_f + col] =
                @as(f32, @floatFromInt(positive - 9)) / 4.0;
        }
    }
    var input_shape = [2]usize{ width, in_f };
    const input: tensor.Tensor = .{
        .dtype = .f32,
        .shape = &input_shape,
        .data = std.mem.sliceAsBytes(&input_values),
        .allocator = std.heap.page_allocator,
    };

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = std.testing.allocator,
        .n_jobs = 3,
    });
    defer pool.deinit();

    var saw_nonzero_winner = false;
    for ([_]u32{ 8, 16 }) |group_size| {
        const weights = try testPatternRows4Weight(
            allocator,
            out_f,
            in_f,
            group_size,
        );
        var materialized_values: [width * out_f]f32 = undefined;
        var materialized_shape = [2]usize{ width, out_f };
        const materialized: tensor.Tensor = .{
            .dtype = .f32,
            .shape = &materialized_shape,
            .data = std.mem.sliceAsBytes(&materialized_values),
            .allocator = std.heap.page_allocator,
        };
        var materialized_q: [width * in_f]i8 = undefined;
        var materialized_scales: [width * 2]f32 = undefined;
        try int4_matmul.linearInt4WeightBatchQ8Parallel(
            &pool,
            input,
            weights,
            &.{},
            materialized,
            out_f,
            in_f,
            &materialized_q,
            &materialized_scales,
            width,
        );

        var expected: [width]u32 = undefined;
        for (0..width) |lane| {
            var winner: GreedyHeadCandidate = .{};
            const logits = materialized_values[lane * out_f ..][0..out_f];
            for (logits, 0..) |value, token_id| {
                try std.testing.expect(!std.math.isNan(value));
                updateGreedyHeadCandidate(&winner, value, token_id);
            }
            try std.testing.expect(winner.valid);
            var winner_count: usize = 0;
            for (logits) |value| {
                winner_count += @intFromBool(value == winner.value);
            }
            // This is intentionally a strict, non-tie oracle. It catches
            // row/scale addressing faults that an all-zero tie cannot.
            try std.testing.expectEqual(@as(usize, 1), winner_count);
            expected[lane] = @intCast(winner.token_id);
            saw_nonzero_winner = saw_nonzero_winner or winner.token_id != 0;
        }

        var streamed_q: [width * in_f]i8 = undefined;
        var streamed_scales: [width * 2]f32 = undefined;
        var streamed = [_]u32{std.math.maxInt(u32)} ** width;
        var telemetry: Telemetry = .{};
        try runStreamingGreedyHead(
            &pool,
            input,
            [_]bool{true} ** width,
            weights,
            &streamed_q,
            &streamed_scales,
            width,
            &streamed,
            &telemetry,
        );
        try std.testing.expectEqual(expected, streamed);
        try std.testing.expectEqual(
            @as(usize, 1),
            telemetry.streaming_greedy_head_m4_dispatches,
        );
        try std.testing.expectEqual(
            @as(usize, width),
            telemetry.streaming_greedy_head_tasks,
        );
        try std.testing.expectEqual(
            @as(usize, width),
            telemetry.streaming_greedy_head_shards,
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            telemetry.streaming_greedy_head_tiles,
        );
        try std.testing.expectEqual(
            @as(usize, width * width),
            telemetry.streaming_greedy_head_lane_candidates,
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            telemetry.streaming_greedy_head_tile_scratch_bytes,
        );

        if (group_size == 16) {
            // A native shard must surface unordered scores without publishing
            // any partial lane decision, including when sibling shards finish.
            @constCast(weights.scales_f16_rows4)[0] = std.math.nan(f16);
            var rejected = [_]u32{0xdead_beef} ** width;
            try std.testing.expectError(
                generate_api.GenerateError.ForwardFailed,
                runStreamingGreedyHead(
                    &pool,
                    input,
                    [_]bool{true} ** width,
                    weights,
                    &streamed_q,
                    &streamed_scales,
                    width,
                    &rejected,
                    null,
                ),
            );
            try std.testing.expectEqual(
                [_]u32{0xdead_beef} ** width,
                rejected,
            );
        }
    }
    try std.testing.expect(saw_nonzero_winner);
}

test "strict streaming B4 policy rejects before any Bank mutation" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var model = try testPreparedModel(68);
    defer model.deinit();
    const prompts = [width][1]u32{ .{0}, .{1}, .{2}, .{3} };
    const valid = testRequests(&prompts);
    const claim = try deriveResourceClaim(
        model,
        valid,
        .{ .num_threads = 2, .greedy_head_mode = .streaming_required },
    );
    var slots: [width]resource_bank.Slot = undefined;
    var bank = try resource_bank.Bank.init(
        &slots,
        .{
            .host_bytes = try claim.hostBytes(),
            .logits_bytes = 0,
            .queue_slots = width,
        },
        0x5334_5245_4a45_4354,
    );
    const initial = try bank.snapshot();
    const forced = [_]u32{0};
    for (0..3) |case| {
        var rejected = valid;
        switch (case) {
            0 => rejected[0].sampler.temperature = 1,
            1 => rejected[1].forced_tokens = &forced,
            2 => rejected[2].eos_token = 0,
            else => unreachable,
        }
        var derive_telemetry: Telemetry = .{
            .greedy_head_mode = .streaming_required,
            .admitted_cohorts = 17,
            .streaming_greedy_head_rejects = 23,
            .fallbacks = 29,
        };
        const derive_telemetry_before = derive_telemetry;
        try std.testing.expectError(
            generate_api.GenerateError.LogitlessGreedyUnavailable,
            deriveResourceClaim(
                model,
                rejected,
                .{
                    .num_threads = 2,
                    .greedy_head_mode = .streaming_required,
                    .telemetry = &derive_telemetry,
                },
            ),
        );
        try std.testing.expectEqualDeep(
            derive_telemetry_before,
            derive_telemetry,
        );

        var telemetry: Telemetry = .{
            .streaming_greedy_head_rejects = 31,
            .fallbacks = 37,
        };
        try std.testing.expectError(
            generate_api.GenerateError.LogitlessGreedyUnavailable,
            generate(
                std.testing.allocator,
                model,
                rejected,
                .{
                    .num_threads = 2,
                    .request_resource_bank = &bank,
                    .greedy_head_mode = .streaming_required,
                    .telemetry = &telemetry,
                },
            ),
        );
        try std.testing.expectEqual(@as(usize, 1), telemetry.streaming_greedy_head_rejects);
        try std.testing.expectEqual(
            GreedyHeadMode.streaming_required,
            telemetry.greedy_head_mode,
        );
        try std.testing.expectEqual(greedy_head_abi, telemetry.greedy_head_abi_version);
        try std.testing.expectEqual(@as(usize, 0), telemetry.admitted_cohorts);
        try std.testing.expectEqual(@as(usize, 0), telemetry.fallbacks);
        try std.testing.expectEqualDeep(initial, try bank.snapshot());
    }
}

test "streaming B4 head enqueue rejection drains work and leaves destination unchanged" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var model = try testPreparedModel(132); // three head tiles, three tasks
    defer model.deinit();
    var hidden_values = [_]f32{1.0} ** (width * 16);
    var hidden_shape = [2]usize{ width, 16 };
    const hidden: tensor.Tensor = .{
        .dtype = .f32,
        .shape = &hidden_shape,
        .data = std.mem.sliceAsBytes(&hidden_values),
        .allocator = std.heap.page_allocator,
    };
    var q_scratch: [width * 16]i8 = undefined;
    var scale_scratch: [width * 16]f32 = undefined;
    var destination = [_]u32{0xdead_beef} ** width;
    var telemetry: Telemetry = .{};

    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{},
    );
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = failing_allocator.allocator(),
        .n_jobs = 2,
    });
    defer pool.deinit();
    // Admit the first background job, then reject the second. The successful
    // job must drain before stack-backed jobs and the wait group leave scope.
    failing_allocator.fail_index = failing_allocator.alloc_index + 1;

    try std.testing.expectError(
        generate_api.GenerateError.OutOfMemory,
        runStreamingGreedyHead(
            &pool,
            hidden,
            [_]bool{true} ** width,
            model.lm_head_int4.?,
            &q_scratch,
            &scale_scratch,
            3,
            &destination,
            &telemetry,
        ),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expectEqual(
        [_]u32{0xdead_beef} ** width,
        destination,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        telemetry.streaming_greedy_head_enqueue_rejects,
    );
    try std.testing.expectEqual(@as(usize, 0), telemetry.fallbacks);
}

test "lane attention enqueue failure drains prior jobs without a serial fallback" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{},
    );
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = failing_allocator.allocator(),
        .n_jobs = 1,
    });
    defer pool.deinit();

    // Pool initialization has completed. Permit exactly one closure so the
    // first lane is genuinely enqueued and the second enqueue fails.
    failing_allocator.fail_index = failing_allocator.alloc_index + 1;

    var q = [2][2]f32{ .{ 1, 0 }, .{ 0, 1 } };
    var k = [2][2]f32{ .{ 1, 0 }, .{ 0, 1 } };
    var v = [2][2]f32{ .{ 3, 4 }, .{ 5, 6 } };
    var out = [2][2]f32{ .{ 0, 0 }, .{ 0, 0 } };
    var jobs = [2]AttentionLaneJob{
        .{
            .q = &q[0],
            .k = &k[0],
            .v = &v[0],
            .out = &out[0],
            .dim = 2,
            .kv_dim = 2,
            .kv_seq = 1,
            .num_heads = 1,
            .head_dim = 2,
            .rope_theta = 10_000,
            .num_kv_heads = 1,
        },
        .{
            .q = &q[1],
            .k = &k[1],
            .v = &v[1],
            .out = &out[1],
            .dim = 2,
            .kv_dim = 2,
            .kv_seq = 1,
            .num_heads = 1,
            .head_dim = 2,
            .rope_theta = 10_000,
            .num_kv_heads = 1,
        },
    };
    var telemetry: Telemetry = .{};
    try std.testing.expectError(
        generate_api.GenerateError.OutOfMemory,
        runLaneAttention(&pool, &jobs, &telemetry),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expect(jobs[0].ran);
    try std.testing.expect(!jobs[1].ran);
    try std.testing.expectEqual(@as(usize, 0), telemetry.lane_parallel_attention_dispatches);
    try std.testing.expectEqual(@as(usize, 0), telemetry.lane_parallel_attention_tasks);
    try std.testing.expectEqual(@as(usize, 1), telemetry.lane_attention_enqueue_rejects);
}

test "state hash enqueue failure drains prior jobs without serial completion" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{},
    );
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = failing_allocator.allocator(),
        .n_jobs = 1,
    });
    defer pool.deinit();
    failing_allocator.fail_index = failing_allocator.alloc_index + 1;

    var caches: [width]kv.KVCache = undefined;
    var initialized: usize = 0;
    defer for (caches[0..initialized]) |*cache| cache.deinit();
    for (&caches) |*cache| {
        cache.* = try kv.KVCache.init(std.testing.allocator, 1, 1, 1);
        initialized += 1;
    }
    var token_storage = [width][1]u32{
        .{11},
        .{22},
        .{33},
        .{44},
    };
    var result: Result = .{
        .allocator = std.testing.allocator,
        .storage = .{
            &token_storage[0],
            &token_storage[1],
            &token_storage[2],
            &token_storage[3],
        },
        .lengths = [_]usize{1} ** width,
    };
    var prngs: [width]std.Random.DefaultPrng = undefined;
    for (&prngs, 0..) |*prng, lane| prng.* = .init(lane + 1);
    var telemetry: Telemetry = .{};
    try std.testing.expectError(
        generate_api.GenerateError.OutOfMemory,
        recordLaneStatesParallel(
            &pool,
            &caches,
            &result,
            [_]usize{1} ** width,
            &prngs,
            &telemetry,
        ),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expect(telemetry.lane_states[0].complete);
    for (telemetry.lane_states[1..]) |state|
        try std.testing.expect(!state.complete);
    try std.testing.expectEqual(
        @as(usize, 0),
        telemetry.state_hash_parallel_dispatches,
    );
    try std.testing.expectEqual(@as(usize, 0), telemetry.state_hash_tasks);
    try std.testing.expectEqual(@as(usize, 1), telemetry.state_hash_enqueue_rejects);
}

test "lane attention exactly preserves long-context MHA and GQA" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const dim: usize = 64;
    const head_dim: usize = 8;
    const num_heads: usize = 8;
    const kv_seq: usize = 257;
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = std.heap.c_allocator,
        .n_jobs = 3,
    });
    defer pool.deinit();

    for ([_]usize{ 8, 2 }) |num_kv_heads| {
        const kv_dim = num_kv_heads * head_dim;
        const kv_lane_elements = kv_seq * kv_dim;
        const q = try std.testing.allocator.alloc(f32, width * dim);
        defer std.testing.allocator.free(q);
        const k = try std.testing.allocator.alloc(f32, width * kv_lane_elements);
        defer std.testing.allocator.free(k);
        const v = try std.testing.allocator.alloc(f32, width * kv_lane_elements);
        defer std.testing.allocator.free(v);
        const expected = try std.testing.allocator.alloc(f32, width * dim);
        defer std.testing.allocator.free(expected);
        const actual = try std.testing.allocator.alloc(f32, width * dim);
        defer std.testing.allocator.free(actual);

        for (q, 0..) |*value, index|
            value.* = @as(f32, @floatFromInt((index * 7 + 3) % 31)) / 64.0;
        for (k, 0..) |*value, index|
            value.* = @as(f32, @floatFromInt((index * 11 + 5) % 37)) / 96.0;
        for (v, 0..) |*value, index|
            value.* = @as(f32, @floatFromInt((index * 13 + 7) % 41)) / 80.0;
        @memset(expected, 0);
        @memset(actual, 0);

        var jobs: [width]AttentionLaneJob = undefined;
        for (0..width) |lane| {
            const q_lane = q[lane * dim ..][0..dim];
            const k_lane = k[lane * kv_lane_elements ..][0..kv_lane_elements];
            const v_lane = v[lane * kv_lane_elements ..][0..kv_lane_elements];
            const expected_lane = expected[lane * dim ..][0..dim];
            const actual_lane = actual[lane * dim ..][0..dim];
            var q_shape: [2]usize = undefined;
            var k_shape: [2]usize = undefined;
            var v_shape: [2]usize = undefined;
            var out_shape: [2]usize = undefined;
            try forward.attentionMultiHead(
                view(q_lane, &q_shape, 1, dim),
                view(k_lane, &k_shape, kv_seq, kv_dim),
                view(v_lane, &v_shape, kv_seq, kv_dim),
                view(expected_lane, &out_shape, 1, dim),
                num_heads,
                head_dim,
                10_000,
                num_kv_heads,
            );
            jobs[lane] = .{
                .q = q_lane,
                .k = k_lane,
                .v = v_lane,
                .out = actual_lane,
                .dim = dim,
                .kv_dim = kv_dim,
                .kv_seq = kv_seq,
                .num_heads = num_heads,
                .head_dim = head_dim,
                .rope_theta = 10_000,
                .num_kv_heads = num_kv_heads,
                .mode = if (num_kv_heads == num_heads)
                    .serial
                else
                    .shared_kv_required,
            };
        }

        var telemetry: Telemetry = .{};
        try runLaneAttention(&pool, &jobs, &telemetry);
        try std.testing.expectEqualSlices(
            u8,
            std.mem.sliceAsBytes(expected),
            std.mem.sliceAsBytes(actual),
        );
        for (jobs) |job| try std.testing.expect(job.ran);
        try std.testing.expectEqual(
            @as(usize, 1),
            telemetry.lane_parallel_attention_dispatches,
        );
        try std.testing.expectEqual(
            @as(usize, width),
            telemetry.lane_parallel_attention_tasks,
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            telemetry.lane_attention_enqueue_rejects,
        );
        try std.testing.expectEqual(
            if (num_kv_heads == num_heads) @as(usize, 0) else width,
            telemetry.shared_kv_attention_lane_dispatches,
        );
        try std.testing.expectEqual(
            if (num_kv_heads == num_heads) @as(usize, 0) else width * 2,
            telemetry.shared_kv_attention_tiles,
        );
    }
}

test "shared-KV required rejects MHA before ResourceBank admission" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var model = try testPreparedModel(68);
    defer model.deinit();
    const prompts = [width][1]u32{ .{0}, .{1}, .{2}, .{3} };
    const requests = testRequests(&prompts);
    try std.testing.expectError(
        generate_api.GenerateError.DecodeLane4Unavailable,
        deriveResourceClaim(model, requests, .{
            .num_threads = 2,
            .attention_mode = .shared_kv_required,
        }),
    );
}
