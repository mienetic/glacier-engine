//! Autoregressive generation using the KV cache.
//!
//! The non-cached forward path recomputes attention over the entire
//! sequence every token — correct but O(N²) per token. This module
//! implements the standard Llama-style generation loop:
//!
//!   1. Pre-fill: run forwardLayerCached for every prompt token, filling
//!      the cache along the way. Cost is O(N²) for the prompt but only
//!      once.
//!   2. Decode: for each new token, run forwardLayerCached for just that
//!      token against the existing cache. Cost per token is O(N).
//!
//! Greedy sampling (argmax) for the MVP — temperature / top-k / top-p
//! are out of scope until the engine produces meaningful probabilities
//! on a real model.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const tensor = core.tensor;
const resource_bank = core.resource_bank;
const forward = @import("forward.zig");
const loader = @import("loader.zig");
const kv = @import("kv_cache.zig");
const int4_executor = @import("int4_executor.zig");
const int4_weights = @import("int4_weights.zig");
const sampling = @import("sampling.zig");

pub const decode_plan_abi = int4_executor.sealed_handoff_abi;
pub const greedy_output_abi = int4_executor.greedy_argmax_abi;
const SealedDecodeLayerPlan = struct {
    handoff: int4_executor.SealedHandoffPlan,
    attention: forward.SealedSharedKvAttentionRecipe,
};
pub const decode_plan_layer_bytes = @sizeOf(SealedDecodeLayerPlan);
pub const decode_plan_slot_bytes = @sizeOf(?SealedDecodeLayerPlan);

pub const Tensor = tensor.Tensor;
pub const TensorError = tensor.TensorError;

pub const GenerateError = error{
    OutOfMemory,
    CacheFull,
    ShapeMismatch,
    ForwardFailed,
    BatchPrefillUnavailable,
    SealedDecodePlanUnavailable,
    LogitlessGreedyUnavailable,
    EligibilityProviderUnavailable,
    EligibilityCertificateRejected,
    MlpRepresentationUnavailable,
    ContextTooLong,
    ResourceBudgetExceeded,
    ResourceAdmissionUnavailable,
    ResourceCommitObserverRejected,
    TokenPublicationObserverRejected,
    TokenTransactionRejected,
    /// A token transaction is already externally committed; only exact
    /// post-publication page reclamation remains pending. Callers must never
    /// retry token generation in response to this error.
    PostPublicationReclaimPending,
    /// At least one token wave is already externally committed and a later
    /// generation/integrity step failed. The caller may resume only from the
    /// published receipt/checkpoint; restarting this request would duplicate
    /// visible tokens.
    PostPublicationGenerationInterrupted,
    DecodeLane4Unavailable,
};

/// Activation precision used by packed INT4 projections.
pub const Int4Activation = enum {
    q8,
    f32,
};

/// Concrete prompt implementation selected for a generation request.
pub const PrefillPath = enum {
    serial,
    batch,
};

/// Explicit decode-plan policy. Benchmarks select both arms directly; strict
/// sealed mode never falls back to the checked graph after admission.
pub const DecodePlanMode = enum {
    checked,
    sealed_required,
};

/// Request-level MLP representation contract. PairNibble is never selected by
/// probing an individual layer: callers must opt in and the complete model is
/// admitted before any request-owned allocation occurs.
pub const MlpRepresentationMode = enum {
    separate,
    pair_nibble_required,
};

/// Request-frame policy used for fail-closed resource A/B. Automatic selects
/// the compact Q8 frame only after all-layer PairNibble admission. The two
/// required arms let one Pair artifact and one binary isolate frame effects.
pub const DecodeFrameMode = enum {
    automatic,
    materialized_required,
    compact_pair_required,
};

/// Private Pair producer resource policy. Automatic keeps separate models at
/// zero Pair allocation and retains fixed-256 for admitted Pair models until
/// the model-shaped no-regression promotion gate passes.
pub const PairScratchMode = enum {
    automatic,
    fixed_256_required,
    model_shaped_required,
};

/// Pair-only packed-prefill activation policy. Automatic deliberately keeps
/// the materialized control until a bounded capsule clears every registered
/// PP128/512/2K promotion gate. Required modes are same-binary evidence arms
/// and never fall back to another prefill representation.
pub const PairPrefillFrameMode = enum {
    automatic,
    materialized_required,
    compact_32_required,
    compact_64_required,
};

pub const PairPrefillFramePolicy = enum {
    disabled,
    materialized,
    compact_32,
    compact_64,
};

const AdmittedMlpRepresentation = enum {
    separate,
    pair_nibble,
};

const PairNibblePhase = enum {
    prefill,
    decode,
};

pub const pair_nibble_storage_abi = int4_weights.pair_nibble_abi;
pub const pair_nibble_executor_abi = int4_executor.pair_nibble_executor_abi;
pub const pair_decode_frame_abi: u64 = 0x4750_4e46_0000_0001;
pub const pair_scratch_abi = int4_executor.pair_scratch_abi;
pub const pair_prefill_frame_abi: u64 = 0x4750_4e50_0000_0001;
pub const prefill_phase_abi: u64 = 0x4750_4853_0000_0001;
pub const request_resource_bank_abi = resource_bank.abi;
/// Synchronous ResourceBank post-commit evidence contract, version 1.
pub const resource_commit_observer_abi: u64 = 0x4752_434f_0000_0001;

/// Immutable, callback-lifetime view of one successfully committed request.
/// The complete receipt is retained so an evidence coordinator can bind every
/// resource class and receipt identity without reconstructing telemetry.
pub const ResourceCommitEvidenceV1 = struct {
    abi: u64 = resource_commit_observer_abi,
    resource_bank_abi: u64 = request_resource_bank_abi,
    receipt: resource_bank.Receipt,
};

/// Callback-local reasons; callers observe only `ResourceCommitObserverRejected`.
pub const ResourceCommitObserverError = error{
    Unavailable,
    InvalidEvidence,
};

/// Optional synchronous evidence hook invoked after ResourceBank commit and
/// telemetry, but before any executor, KV, frame, logits, or output allocation.
/// `context` and the callback must remain valid for the complete `generate`
/// call; callback views must not be retained. Concurrent M1 calls may share an
/// observer, so shared context must be synchronized and the callback must be
/// reentrant. A callback may deliberately block while coordinating a
/// measurement cohort, but that behavior is for evidence collection only and
/// must not be used as production scheduling.
pub const ResourceCommitObserver = struct {
    abi: u64 = resource_commit_observer_abi,
    context: *anyopaque,
    observe: *const fn (
        context: *anyopaque,
        evidence: *const ResourceCommitEvidenceV1,
    ) ResourceCommitObserverError!void,
};

/// Synchronous logical-token publication evidence contract, version 1.
pub const token_publication_observer_abi: u64 = 0x4754_504f_0000_0001;

/// Immutable callback-lifetime view of one token after it enters the private
/// output journal but before a successful generation result is returned.
pub const TokenPublicationEvidenceV1 = struct {
    abi: u64 = token_publication_observer_abi,
    logical_request_index: u32,
    step_index: u64,
    token_id: u32,
    terminal: bool,
};

pub const TokenPublicationObserverError = error{
    Unavailable,
    InvalidEvidence,
};

/// Optional contextful token observer for grounded runners. Ordinary M1 sets
/// `logical_request_index` per request; DecodeLane4 substitutes the actual
/// lane for every callback. Shared callback context must be synchronized and
/// reentrant when four M1 requests execute concurrently.
pub const TokenPublicationObserver = struct {
    abi: u64 = token_publication_observer_abi,
    logical_request_index: u32 = 0,
    context: *anyopaque,
    observe: *const fn (
        context: *anyopaque,
        evidence: *const TokenPublicationEvidenceV1,
    ) TokenPublicationObserverError!void,
};

/// Execution-lifetime receipt for the checked logical maximum request claim
/// admitted before executor, KV, output, activation, logits, and plan
/// allocations. The v1 scope excludes allocator padding/metadata, inline and
/// worker-stack state, OS thread state, legacy libc-pool internals, external
/// provider allocations, mapped model pages, and OS/device residency. This is
/// same-source Zig telemetry rather than a stable C binary layout; persisted
/// evidence must use a versioned canonical runner schema.
pub const RequestResourceTelemetry = struct {
    owner_key: u64 = 0,
    bank_epoch: u64 = 0,
    receipt_slot_index: u32 = std.math.maxInt(u32),
    receipt_generation: u64 = 0,
    receipt_integrity: u64 = 0,
    host_limit_bytes: u64 = 0,
    host_claim_bytes: u64 = 0,
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
    peak_host_bytes: u64 = 0,
    reservations: u64 = 0,
    commits: u64 = 0,
    cancellations: u64 = 0,
    releases: u64 = 0,
    capacity_rejects: u64 = 0,
    slot_rejects: u64 = 0,
    active_reservations: usize = 0,
    committed_receipts: usize = 0,
    active_child_leases: usize = 0,
    child_lease_abi_version: u64 = 0,
    child_key: u64 = 0,
    child_generation: u64 = 0,
    child_integrity: u64 = 0,
    child_ceiling_kv_bytes: u64 = 0,
    child_current_kv_bytes: u64 = 0,
    logical_kv_capacity_bytes: u64 = 0,
    child_opens: u64 = 0,
    child_grows: u64 = 0,
    child_shrinks: u64 = 0,
    child_closes: u64 = 0,
    child_capacity_rejects: u64 = 0,
    derive_rejects: usize = 0,
    release_failures: usize = 0,
};

/// Completion-state receipt used to compare independent generation with a
/// cohort scheduler. KV values are hashed in canonical little-endian f32-bit
/// order and output tokens in little-endian u32 order. `rng_state` is the full
/// Xoshiro256 state after generation; unlike a next-value probe it proves the
/// complete deterministic transition without mutating the generator.
pub const generation_state_abi: u64 = 0x4747_5354_0000_0001;
pub const generation_rng_abi: u64 = 0x584f_5332_3536_0001;

pub const GenerationStateTelemetry = struct {
    abi_version: u64 = generation_state_abi,
    rng_abi: u64 = generation_rng_abi,
    complete: bool = false,
    kv_positions: usize = 0,
    published_tokens: usize = 0,
    sampling_calls: usize = 0,
    kv_sha256: [32]u8 = [_]u8{0} ** 32,
    output_sha256: [32]u8 = [_]u8{0} ** 32,
    rng_state: [4]u64 = [_]u64{0} ** 4,
};

/// Completed logical-work receipt for the strict serial PairNibble arm used as
/// DecodeLane4's four-request oracle. Graph cardinalities are credited only
/// after the whole engine token graph or LM head returns successfully. They
/// prove the admitted strict schedule completed; they are not lower-level
/// hardware-dispatch counters. The request is retainable only when `complete`
/// is true.
pub const request_execution_telemetry_abi: u64 = 0x474d_3145_0000_0002;

pub const RequestExecutionTelemetry = struct {
    abi_version: u64 = request_execution_telemetry_abi,
    complete: bool = false,
    admitted_requests: usize = 0,
    thread_participants: usize = 0,
    prompt_token_graphs: usize = 0,
    decode_token_graphs: usize = 0,
    token_graphs: usize = 0,
    layer_graphs: usize = 0,
    /// Completed logical Q, K, V, O, and prepared-down operations. Pair
    /// producer and LM head remain separate so neither can disappear from the
    /// strict graph receipt.
    projection_dispatches: usize = 0,
    qkv_projection_dispatches: usize = 0,
    pair_dispatches: usize = 0,
    lm_head_dispatches: usize = 0,
    active_lane_steps: usize = 0,
};

pub const PairScratchExecutionTelemetry = struct {
    selected_policy: int4_executor.PairScratchPolicy = .disabled,
    participants: usize = 0,
    producer_g8_layers: usize = 0,
    producer_g16_layers: usize = 0,
    selected_g8_rows: usize = 0,
    selected_g16_rows: usize = 0,
    capacity_rows: usize = 0,
    branch_stride_rows: usize = 0,
    participant_stride_rows: usize = 0,
    f32_elements: usize = 0,
    bytes: usize = 0,
    fixed_counterfactual_bytes: usize = 0,
    reclaimed_bytes: usize = 0,
    allocations: usize = 0,
    fixed_dispatches: u64 = 0,
    model_shaped_dispatches: u64 = 0,
    fallbacks: usize = 0,
    rejects: usize = 0,
};

/// Logical typed-payload receipt for one request-local packed-prefill arena.
/// Byte fields exclude allocator metadata/padding and OS residency. Compact
/// Pair policies bound producer storage by a prompt-row capsule, independent
/// of the outer 256-row causal chunk and model depth.
pub const PairPrefillFrameTelemetry = struct {
    selected_policy: PairPrefillFramePolicy = .disabled,
    producer_g8_layers: usize = 0,
    producer_g16_layers: usize = 0,
    down_g8_layers: usize = 0,
    down_g16_layers: usize = 0,
    chunk_capacity: usize = 0,
    chunk_count: usize = 0,
    full_chunks: usize = 0,
    tail_chunks: usize = 0,
    peak_active_rows: usize = 0,
    capsule_rows: usize = 0,
    tile_rows: usize = 0,
    task_slots: usize = 0,
    materialized_layer_uses: usize = 0,
    compact_layer_uses: usize = 0,
    capsules: usize = 0,
    pair_input_rows: usize = 0,
    pair_output_rows: usize = 0,
    prepared_down_rows: usize = 0,
    prepared_down_dispatches: usize = 0,
    common_payload_bytes: usize = 0,
    gate_bytes: usize = 0,
    up_bytes: usize = 0,
    silu_bytes: usize = 0,
    q_scratch_bytes: usize = 0,
    scale_scratch_bytes: usize = 0,
    pair_q8_bytes: usize = 0,
    pair_scale_bytes: usize = 0,
    gate_tile_bytes: usize = 0,
    up_tile_bytes: usize = 0,
    tensor_payload_bytes: usize = 0,
    materialized_counterfactual_bytes: usize = 0,
    reclaimed_tensor_payload_bytes: usize = 0,
    arena_sets: usize = 0,
    logical_slices: usize = 0,
    fallbacks: usize = 0,
    rejects: usize = 0,
};

/// Request-local proof that a strict PairNibble request used one homogeneous
/// artifact and the dedicated consumer for every selected layer. The
/// existing `paired_mlp_*` phase counters describe a different optimization
/// (two separate projections followed by a typed SwiGLU bridge) and are kept
/// deliberately separate.
pub const PairNibbleExecutionTelemetry = struct {
    admissions: usize = 0,
    artifact_layers: usize = 0,
    selected_layers: usize = 0,
    pair_weight_bytes: usize = 0,
    pair_scale_bytes: usize = 0,
    separate_gate_bytes: usize = 0,
    separate_up_bytes: usize = 0,
    down_g8_layers: usize = 0,
    down_g16_layers: usize = 0,
    decode_frame_materialized_uses: usize = 0,
    decode_frame_compact_pair_uses: usize = 0,
    decode_frame_tensor_bytes: usize = 0,
    decode_frame_materialized_bytes: usize = 0,
    decode_frame_reclaimed_bytes: usize = 0,
    pair_q8_scratch_bytes: usize = 0,
    pair_activation_scale_bytes: usize = 0,
    prefill_m1_dispatches: usize = 0,
    prefill_m4_groups: usize = 0,
    prefill_tail_dispatches: usize = 0,
    prefill_tail_rows: usize = 0,
    decode_m1_dispatches: usize = 0,
    outputless_m1_dispatches: usize = 0,
    activation_rows_quantized: usize = 0,
    selected_layer_rows: usize = 0,
    checked_dispatches: usize = 0,
    sealed_dispatches: usize = 0,
    fallbacks: usize = 0,
    rejects: usize = 0,
};

/// Greedy output policy. The strict arm returns the exact token index from
/// bounded LM-head tiles and never silently materializes decode logits.
pub const GreedyOutputMode = enum {
    materialized,
    logitless_required,
    /// Compute the complete LM head, then apply a required caller-certified
    /// vocabulary domain with the engine's canonical greedy reducer.
    domain_posthead_required,
    /// Apply the same required domain before LM-head dot products. Empty
    /// rows4 groups are skipped and full-vocabulary logits never exist.
    domain_prehead_required,
};

pub const GreedyOutputTelemetry = struct {
    materialized_projections: usize = 0,
    logitless_projections: usize = 0,
    producer_rows: usize = 0,
    tile_output_bytes: usize = 0,
    argmax_scan_rows: usize = 0,
    scratch_bytes: usize = 0,
    materialized_logits_bytes: usize = 0,
    steady_state_reclaimed_bytes: usize = 0,
    fallbacks: usize = 0,
    rejects: usize = 0,
};

/// Versioned synchronous contract between a semantic constraint producer and
/// generation. This is deliberately separate from the executor eligibility
/// ABI: the provider binds a token prefix and policy to each mask, while the
/// executor only consumes the already sealed bitset.
pub const eligibility_provider_abi: u64 = 0x474c_5643_0000_0001;

pub const EligibilityTieRule = enum(u8) {
    invalid = 0,
    lowest_token_id = 1,
};

pub const EligibilityOperation = enum(u8) {
    invalid = 0,
    greedy_argmax = 1,
};

/// Immutable request view supplied to the provider. `logits_position` is the
/// absolute token position whose hidden state feeds this LM head: prompt.len-1
/// for step zero, then prompt.len+step-1. All slices are callback-only.
pub const EligibilityStepV1 = struct {
    generation_epoch: u64,
    request_nonce: u64,
    step_index: u64,
    logits_position: u64,
    prompt: []const u32,
    generated_prefix: []const u32,
    vocab_size: usize,
    head_binding: [32]u8,
    tokenizer_binding: [32]u8,
    policy_binding: [32]u8,
    prefix_sha256: [32]u8,
};

/// Evidence returned alongside the writable staging mask. Echoed step and
/// identity fields prevent stale/cross-model certificates from being used.
/// The engine hashes its private copy and verifies every field before compute.
pub const EligibilityCertificateV1 = struct {
    abi: u64 = 0,
    generation_epoch: u64 = 0,
    request_nonce: u64 = 0,
    step_index: u64 = 0,
    logits_position: u64 = 0,
    not_after_step: u64 = 0,
    head_binding: [32]u8 = [_]u8{0} ** 32,
    tokenizer_binding: [32]u8 = [_]u8{0} ** 32,
    policy_binding: [32]u8 = [_]u8{0} ** 32,
    prefix_sha256: [32]u8 = [_]u8{0} ** 32,
    mask_sha256: [32]u8 = [_]u8{0} ** 32,
    eligible_rows: usize = 0,
    tie_rule: EligibilityTieRule = .invalid,
    operation: EligibilityOperation = .invalid,
};

pub const EligibilityProviderError = error{
    Unavailable,
    InvalidEvidence,
    OutOfMemory,
};

/// The callback may write only `staging_words` and `certificate`, must return
/// synchronously, and must not retain or concurrently access callback views.
/// Generation copies the mask into engine-private storage before validation
/// and never exposes that private execution copy to the provider. `context`
/// must outlive the complete synchronous `generate` call; a context shared by
/// concurrent requests must provide its own synchronization.
pub const EligibleVocabularyProvider = struct {
    abi: u64 = eligibility_provider_abi,
    context: *anyopaque,
    generation_epoch: u64,
    head_binding: [32]u8,
    tokenizer_binding: [32]u8,
    policy_binding: [32]u8,
    fill: *const fn (
        context: *anyopaque,
        step: *const EligibilityStepV1,
        staging_words: []u64,
        certificate: *EligibilityCertificateV1,
    ) EligibilityProviderError!void,
};

/// Separate telemetry preserves the stable `greedy_output:` CLI contract.
/// Every row counter describes work actually completed for certified heads.
pub const EligibilityTelemetry = struct {
    provider_calls: usize = 0,
    certificates_accepted: usize = 0,
    posthead_projections: usize = 0,
    prehead_projections: usize = 0,
    eligible_rows: usize = 0,
    materialized_dot_rows: usize = 0,
    producer_rows: usize = 0,
    skipped_rows: usize = 0,
    overcomputed_rows: usize = 0,
    producer_runs: usize = 0,
    full_logits_rows_written: usize = 0,
    full_logits_peak_bytes: usize = 0,
    staging_mask_bytes: usize = 0,
    sealed_mask_bytes: usize = 0,
    executor_candidate_bytes: usize = 0,
    executor_tile_scratch_bytes: usize = 0,
    provider_ns: u64 = 0,
    verification_ns: u64 = 0,
    request_nonce: u64 = 0,
    published_tokens: usize = 0,
    fallbacks: usize = 0,
    rejects: usize = 0,
    last_mask_sha256: [32]u8 = [_]u8{0} ** 32,
    trace_sha256: [32]u8 = [_]u8{0} ** 32,
};

/// Separate plan telemetry keeps the stable phase line backward compatible
/// while proving full-layer coverage and exposing cold construction cost.
pub const DecodePlanTelemetry = struct {
    plan_sets: usize = 0,
    plan_set_bytes: usize = 0,
    layer_builds: usize = 0,
    layer_binds: usize = 0,
    checked_dispatches: usize = 0,
    sealed_dispatches: usize = 0,
    fallbacks: usize = 0,
    rejects: usize = 0,
    build_ns: u64 = 0,
};

/// Process-relative request-ready timestamp captured after request buffers and
/// worker threads exist but before the first prompt token executes.
pub const RequestReadyTelemetry = struct {
    process_timer: *std.time.Timer,
    elapsed_ns_out: *u64,
};

/// Request-local phase timings. These boundaries intentionally exclude model
/// loading and request-buffer/worker setup: prefill starts immediately before
/// the first prompt graph, decode covers every graph needed after an emitted
/// token, and sampling covers only token selection from logits.
pub const GenerationPhaseTelemetry = struct {
    prefill_ns: u64 = 0,
    prefill_graph_ns: u64 = 0,
    first_head_ns: u64 = 0,
    decode_graph_ns: u64 = 0,
    sampling_ns: u64 = 0,
    decode_graph_runs: usize = 0,
    parallel_attention_graphs: usize = 0,
    parallel_attention_dispatches: usize = 0,
    handoff_graphs: usize = 0,
    handoff_dispatches: usize = 0,
    fused_gqa_graphs: usize = 0,
    fused_gqa_dispatches: usize = 0,
    paired_mlp_graphs: usize = 0,
    paired_mlp_dispatches: usize = 0,
};

/// Observer used by teacher-forced scoring. The callback receives the logits
/// that predict `target_token` before that token is fed into the KV cache.
pub const LogitsObserver = struct {
    context: *anyopaque,
    observe: *const fn (context: *anyopaque, logits: []const f32, target_token: u32) void,
};

const CoreTopology = struct {
    performance: usize,
    efficiency: usize,
};

fn readDarwinCoreCount(name: [*:0]const u8) ?usize {
    if (comptime builtin.os.tag != .macos) return null;
    var count: c_uint = 0;
    var count_len: usize = @sizeOf(c_uint);
    std.posix.sysctlbynameZ(name, &count, &count_len, null, 0) catch return null;
    if (count_len != @sizeOf(c_uint) or count == 0) return null;
    return @intCast(count);
}

fn detectCoreTopology() ?CoreTopology {
    const performance = readDarwinCoreCount("hw.perflevel0.logicalcpu") orelse return null;
    const efficiency = readDarwinCoreCount("hw.perflevel1.logicalcpu") orelse return null;
    return .{ .performance = performance, .efficiency = efficiency };
}

fn selectDecodeThreadCount(cpu_count: usize, topology: ?CoreTopology) usize {
    if (cpu_count <= 1) return 1;
    const ceiling = @min(cpu_count, 8);
    const cores = topology orelse return ceiling;
    // Packed decode is memory/instruction-bandwidth bound. On asymmetric
    // Apple CPUs, using every E-core increases contention and tail latency;
    // retain all P-cores plus half of the E-cluster for useful work stealing.
    const asymmetric = cores.performance + cores.efficiency;
    if (cores.performance == 0 or cores.efficiency == 0 or asymmetric > cpu_count)
        return ceiling;
    return @min(ceiling, cores.performance + (cores.efficiency + 1) / 2);
}

/// Parallel attention/HandoffGraph is an explicit experimental schedule. The
/// exact shared-K/V GQA kernel passes retained p176+n64 and TG512 latency gates,
/// but the first balanced resource probe exceeds the CPU-time/cycle budget.
/// Production therefore fails safe to serial until an energy-aware schedule
/// passes the remaining promotion gate.
pub const default_parallel_attention_min_context: ?usize = null;

fn shouldParallelizeAttention(
    context_len: usize,
    num_heads: usize,
    participants: usize,
    min_context: ?usize,
) bool {
    const threshold = min_context orelse return false;
    return context_len >= threshold and num_heads > 1 and participants > 1;
}

fn validateModelLayerCount(configured: usize, loaded: usize) GenerateError!void {
    if (configured == 0 or configured != loaded) return GenerateError.ShapeMismatch;
}

/// Close one decode graph's attention accounting before its KV state commits.
/// Successful parallel graphs contribute exactly one dispatch per layer;
/// Handoff, fused-GQA, and paired-MLP subgraphs may contribute only zero or
/// the same complete layer count. Any partial, regressed, or previously
/// inconsistent count fails closed instead of publishing ambiguous telemetry.
fn finishParallelAttentionGraph(
    telemetry: *GenerationPhaseTelemetry,
    dispatches_before: usize,
    handoff_dispatches_before: usize,
    fused_gqa_dispatches_before: usize,
    paired_mlp_dispatches_before: usize,
    layer_count: usize,
) GenerateError!void {
    if (layer_count == 0 or telemetry.parallel_attention_dispatches < dispatches_before or
        telemetry.handoff_dispatches < handoff_dispatches_before or
        telemetry.fused_gqa_dispatches < fused_gqa_dispatches_before or
        telemetry.paired_mlp_dispatches < paired_mlp_dispatches_before or
        telemetry.handoff_dispatches > telemetry.parallel_attention_dispatches or
        telemetry.fused_gqa_dispatches > telemetry.handoff_dispatches or
        telemetry.paired_mlp_dispatches > telemetry.handoff_dispatches)
        return GenerateError.ForwardFailed;
    const expected_before = std.math.mul(
        usize,
        telemetry.parallel_attention_graphs,
        layer_count,
    ) catch return GenerateError.ForwardFailed;
    if (dispatches_before != expected_before) return GenerateError.ForwardFailed;
    const expected_handoff_before = std.math.mul(
        usize,
        telemetry.handoff_graphs,
        layer_count,
    ) catch return GenerateError.ForwardFailed;
    if (handoff_dispatches_before != expected_handoff_before)
        return GenerateError.ForwardFailed;
    const expected_fused_before = std.math.mul(
        usize,
        telemetry.fused_gqa_graphs,
        layer_count,
    ) catch return GenerateError.ForwardFailed;
    if (fused_gqa_dispatches_before != expected_fused_before)
        return GenerateError.ForwardFailed;
    const expected_paired_mlp_before = std.math.mul(
        usize,
        telemetry.paired_mlp_graphs,
        layer_count,
    ) catch return GenerateError.ForwardFailed;
    if (paired_mlp_dispatches_before != expected_paired_mlp_before)
        return GenerateError.ForwardFailed;

    const graph_dispatches = telemetry.parallel_attention_dispatches - dispatches_before;
    const graph_handoffs = telemetry.handoff_dispatches - handoff_dispatches_before;
    const graph_fused_gqa = telemetry.fused_gqa_dispatches - fused_gqa_dispatches_before;
    const graph_paired_mlp = telemetry.paired_mlp_dispatches - paired_mlp_dispatches_before;
    if (graph_dispatches == 0) {
        if (graph_handoffs != 0 or graph_fused_gqa != 0 or graph_paired_mlp != 0)
            return GenerateError.ForwardFailed;
        return;
    }
    if (graph_dispatches != layer_count) return GenerateError.ForwardFailed;
    if (graph_handoffs != 0 and graph_handoffs != layer_count)
        return GenerateError.ForwardFailed;
    if (graph_fused_gqa != 0 and graph_fused_gqa != layer_count)
        return GenerateError.ForwardFailed;
    if (graph_paired_mlp != 0 and graph_paired_mlp != layer_count)
        return GenerateError.ForwardFailed;
    if (graph_fused_gqa == layer_count and graph_handoffs != layer_count)
        return GenerateError.ForwardFailed;
    if (graph_paired_mlp == layer_count and graph_handoffs != layer_count)
        return GenerateError.ForwardFailed;

    const next_graphs = std.math.add(
        usize,
        telemetry.parallel_attention_graphs,
        1,
    ) catch return GenerateError.ForwardFailed;
    const expected_after = std.math.mul(usize, next_graphs, layer_count) catch
        return GenerateError.ForwardFailed;
    if (telemetry.parallel_attention_dispatches != expected_after)
        return GenerateError.ForwardFailed;
    telemetry.parallel_attention_graphs = next_graphs;
    if (graph_handoffs == layer_count) {
        const next_handoff_graphs = std.math.add(
            usize,
            telemetry.handoff_graphs,
            1,
        ) catch return GenerateError.ForwardFailed;
        const expected_handoff_after = std.math.mul(
            usize,
            next_handoff_graphs,
            layer_count,
        ) catch return GenerateError.ForwardFailed;
        if (telemetry.handoff_dispatches != expected_handoff_after)
            return GenerateError.ForwardFailed;
        telemetry.handoff_graphs = next_handoff_graphs;
    }
    if (graph_fused_gqa == layer_count) {
        const next_fused_graphs = std.math.add(
            usize,
            telemetry.fused_gqa_graphs,
            1,
        ) catch return GenerateError.ForwardFailed;
        const expected_fused_after = std.math.mul(
            usize,
            next_fused_graphs,
            layer_count,
        ) catch return GenerateError.ForwardFailed;
        if (telemetry.fused_gqa_dispatches != expected_fused_after)
            return GenerateError.ForwardFailed;
        telemetry.fused_gqa_graphs = next_fused_graphs;
    }
    if (graph_paired_mlp == layer_count) {
        const next_paired_mlp_graphs = std.math.add(
            usize,
            telemetry.paired_mlp_graphs,
            1,
        ) catch return GenerateError.ForwardFailed;
        const expected_paired_mlp_after = std.math.mul(
            usize,
            next_paired_mlp_graphs,
            layer_count,
        ) catch return GenerateError.ForwardFailed;
        if (telemetry.paired_mlp_dispatches != expected_paired_mlp_after)
            return GenerateError.ForwardFailed;
        telemetry.paired_mlp_graphs = next_paired_mlp_graphs;
    }
}

/// Precomputed rotary factors shared by every layer during one generation.
/// The old decode path evaluated pow/cos/sin inside every layer/token pair;
/// this table makes RoPE a pair of indexed loads in the hot loop.
const RopeTable = struct {
    allocator: std.mem.Allocator,
    cos: []f32,
    sin: []f32,
    positions: usize,
    half_dim: usize,

    fn init(allocator: std.mem.Allocator, positions: usize, head_dim: usize, theta: f32) !RopeTable {
        const half_dim = head_dim / 2;
        const count = std.math.mul(usize, positions, half_dim) catch return error.OutOfMemory;
        const cos = try allocator.alloc(f32, count);
        errdefer allocator.free(cos);
        const sin = try allocator.alloc(f32, count);
        errdefer allocator.free(sin);
        for (0..positions) |pos| {
            for (0..half_dim) |pair| {
                const exponent = @as(f32, @floatFromInt(2 * pair)) / @as(f32, @floatFromInt(head_dim));
                const freq = 1.0 / std.math.pow(f32, theta, exponent);
                const angle = @as(f32, @floatFromInt(pos)) * freq;
                cos[pos * half_dim + pair] = std.math.cos(angle);
                sin[pos * half_dim + pair] = std.math.sin(angle);
            }
        }
        return .{ .allocator = allocator, .cos = cos, .sin = sin, .positions = positions, .half_dim = half_dim };
    }

    fn deinit(self: *RopeTable) void {
        self.allocator.free(self.cos);
        self.allocator.free(self.sin);
    }

    fn apply(self: *const RopeTable, row: []f32, pos: usize, num_heads: usize, head_dim: usize) void {
        if (pos >= self.positions or head_dim / 2 != self.half_dim) return;
        const factors = pos * self.half_dim;
        for (0..num_heads) |head| {
            const head_off = head * head_dim;
            for (0..self.half_dim) |pair| {
                const idx0 = head_off + pair;
                const idx1 = head_off + pair + self.half_dim;
                const x0 = row[idx0];
                const x1 = row[idx1];
                const c = self.cos[factors + pair];
                const s = self.sin[factors + pair];
                row[idx0] = x0 * c - x1 * s;
                row[idx1] = x0 * s + x1 * c;
            }
        }
    }
};

const ProjectionTask = struct {
    run: *const fn (*anyopaque) void,
    args: *anyopaque,
};

/// Persistent single worker used to overlap the independent projection
/// branch with the caller.  A fresh `std.Thread.spawn` per layer was visible
/// in profiles; this keeps the same nested use of the decode pool without
/// paying OS thread creation and teardown costs for every token.
const ProjectionWorker = struct {
    thread: std.Thread = undefined,
    mutex: std.Thread.Mutex = .{},
    work: std.Thread.Condition = .{},
    done: std.Thread.Condition = .{},
    task: ?ProjectionTask = null,
    busy: bool = false,
    completed: bool = false,
    stopping: bool = false,

    fn init(self: *ProjectionWorker) !void {
        self.* = .{};
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    fn workerMain(self: *ProjectionWorker) void {
        while (true) {
            self.mutex.lock();
            while (self.task == null and !self.stopping) self.work.wait(&self.mutex);
            if (self.stopping) {
                self.mutex.unlock();
                return;
            }
            const task = self.task.?;
            self.task = null;
            self.mutex.unlock();

            task.run(task.args);

            self.mutex.lock();
            self.busy = false;
            self.completed = true;
            self.done.broadcast();
            self.work.broadcast();
            self.mutex.unlock();
        }
    }

    fn start(self: *ProjectionWorker, task: ProjectionTask) void {
        self.mutex.lock();
        while (self.busy) self.work.wait(&self.mutex);
        self.busy = true;
        self.completed = false;
        self.task = task;
        self.work.signal();
        self.mutex.unlock();
    }

    fn wait(self: *ProjectionWorker) void {
        self.mutex.lock();
        while (!self.completed) self.done.wait(&self.mutex);
        self.mutex.unlock();
    }

    fn deinit(self: *ProjectionWorker) void {
        self.mutex.lock();
        const was_busy = self.busy;
        self.mutex.unlock();
        if (was_busy) self.wait();
        self.mutex.lock();
        self.stopping = true;
        self.work.signal();
        self.mutex.unlock();
        self.thread.join();
    }
};

pub const GenerateOptions = struct {
    /// Maximum tokens to generate (excluding the prompt).
    max_new_tokens: usize,
    /// Stop token id; generation halts if produced. Set to a value outside
    /// vocab range to disable.
    eos_token: u32 = std.math.maxInt(u32),
    /// Sampling configuration. Defaults to greedy (temperature 0).
    sampler: sampling.SamplerConfig = .{ .temperature = 0 },
    /// RNG seed for reproducible sampling. Ignored when sampler.temperature == 0.
    seed: u64 = 0,
    /// Total decode threads, including the caller. Zero selects a
    /// topology-aware count up to eight; one forces the serial packed kernel.
    num_threads: usize = 0,
    /// Q8 block activations are the fast packed-INT4 path. `.f32` preserves
    /// the pre-Q8 reference path for quality comparisons.
    int4_activation: Int4Activation = .q8,
    /// Allocation-free persistent projection executor with dynamic row-tile
    /// stealing. False retains the legacy closure-based pool for A/B tests.
    use_persistent_executor: bool = true,
    /// Exact MLP storage/execution contract for this request. The default
    /// accepts only conventional separate gate/up storage. PairNibble must be
    /// explicitly required and then cannot fall back to separate projections.
    mlp_representation: MlpRepresentationMode = .separate,
    /// Exact decode activation-frame contract. Compact-required is valid only
    /// with an admitted PairNibble request; materialized-required is retained
    /// solely as the same-artifact resource/latency control arm.
    decode_frame_mode: DecodeFrameMode = .automatic,
    /// Exact Pair producer private-tile resource contract. Required modes are
    /// fail-closed controls; automatic retains the evidence control until the
    /// model-shaped candidate clears its registered promotion gate.
    pair_scratch_mode: PairScratchMode = .automatic,
    pair_scratch_telemetry: ?*PairScratchExecutionTelemetry = null,
    /// Pair-only batch-prefill frame contract. Required modes imply that the
    /// packed prefill path must execute; automatic keeps the materialized
    /// control pending replicated graph-time and physical-resource evidence.
    pair_prefill_frame_mode: PairPrefillFrameMode = .automatic,
    pair_prefill_frame_telemetry: ?*PairPrefillFrameTelemetry = null,
    /// Optional shared admission authority. The complete logical request claim
    /// is reserved and committed before request-owned allocations, then
    /// released exactly once after the returned output journal is transferred
    /// to the caller. Servers provide multiple slots and a process-wide cap;
    /// the CLI uses one slot and an optional hard host-byte limit.
    request_resource_bank: ?*resource_bank.Bank = null,
    request_resource_telemetry: ?*RequestResourceTelemetry = null,
    /// Optional fail-closed post-commit evidence observer. It requires a
    /// ResourceBank and a non-empty generation request. null adds no snapshot,
    /// allocation, timing, or callback work to the ordinary execution path.
    resource_commit_observer: ?ResourceCommitObserver = null,
    /// Optional request-local PairNibble admission, storage, and dispatch
    /// evidence. Reset before representation admission.
    pair_nibble_telemetry: ?*PairNibbleExecutionTelemetry = null,
    /// Minimum live KV rows before cached decode distributes attention by
    /// query-head range. `null` forces serial attention; explicit values (for
    /// example 128/256/512) support arithmetic-identical crossover A/B runs.
    /// The production default is serial; prefill also stays serial.
    parallel_attention_min_context: ?usize = default_parallel_attention_min_context,
    /// Repeated graph validation remains the compatibility oracle. Strict
    /// sealed mode requires the AArch64 compact rows4 prepared topology and
    /// rejects ineligible requests instead of silently changing paths.
    decode_plan_mode: DecodePlanMode = .checked,
    /// Optional request-local plan counters and construction timing.
    decode_plan_telemetry: ?*DecodePlanTelemetry = null,
    /// Strict greedy LM-head policy. Legacy logitless mode keeps one
    /// materialized prompt head; domain-prehead applies its certified mask to
    /// every head, including step zero, and never allocates full logits.
    greedy_output_mode: GreedyOutputMode = .materialized,
    /// Optional request-local output-path coverage and storage telemetry.
    greedy_output_telemetry: ?*GreedyOutputTelemetry = null,
    /// Required, versioned semantic domain for the two `domain_*` output
    /// policies. Providing it to any other policy is rejected so evidence can
    /// never be accepted but silently ignored.
    eligible_vocabulary_provider: ?EligibleVocabularyProvider = null,
    /// Optional request-local certificate, row-work, storage, and transcript
    /// counters. This is reset at request admission.
    eligibility_telemetry: ?*EligibilityTelemetry = null,
    /// Reuse each packed weight tile across four prompt rows and process the
    /// prompt in causal chunks. False retains token-at-a-time prefill for
    /// exact A/B measurements and as a compatibility escape hatch.
    use_batch_prefill: bool = true,
    /// Fail closed unless the packed batch path actually completes. This is
    /// intended for benchmark harnesses that must never time a silent fallback.
    require_batch_prefill: bool = false,
    /// Optional request-local result slot for benchmark observability.
    prefill_path_out: ?*PrefillPath = null,
    /// Optional process-relative ready boundary for end-to-end startup
    /// measurement. The caller owns both pointers for the whole request.
    request_ready_telemetry: ?RequestReadyTelemetry = null,
    /// Optional phase-level timing for benchmark observability. The caller
    /// owns the result slot for the whole request.
    phase_telemetry: ?*GenerationPhaseTelemetry = null,
    /// Optional exact completion-state receipt. This is intentionally off by
    /// default because hashing the logical KV payload is O(context * layers).
    generation_state_telemetry: ?*GenerationStateTelemetry = null,
    /// Optional actual-work receipt for the strict serial PairNibble M1 oracle.
    /// Supplying it makes unsupported scheduling/output combinations reject
    /// instead of publishing counters for a different execution graph.
    request_execution_telemetry: ?*RequestExecutionTelemetry = null,
    /// Optional teacher-forced continuation. When non-empty, its length must
    /// equal `max_new_tokens`; sampling is bypassed but the normal cached Q8
    /// graph still runs for every supplied token.
    forced_tokens: []const u32 = &.{},
    /// Fail-closed, contextful publication observer used by grounded runners.
    /// It runs once per journaled token before the legacy streaming callback.
    token_publication_observer: ?TokenPublicationObserver = null,
    /// Optional per-step logits observer, primarily for cached perplexity.
    logits_observer: ?LogitsObserver = null,
    /// Optional callback invoked for every generated token right after it
    /// is sampled. Useful for streaming output. null = no callback.
    on_token: ?*const fn (token: u32) void = null,
};

/// Run one layer for a single new token, using the cache for past K/V.
///
/// `x_row`: [1, dim] activations for the new token.
/// `cache_layer_idx`: index into the KV cache for this layer.
/// `cur_pos`: absolute position of this token (used for RoPE).
/// `out_row`: [1, dim] output activations (caller-allocated).
///
/// Side effects: appends one K row and one V row to the cache for this
/// layer. The caller must call cache.commit() once all layers are done.
const decode_buffers = @import("decode_buffers.zig");
const prefill_buffers = @import("prefill_buffers.zig");
const f16_matmul = @import("backends/cpu/f16_matmul.zig");
const dotproduct = @import("backends/cpu/dotproduct.zig");
const int4_matmul = @import("backends/cpu/int4_matmul.zig");

fn projectLinear(
    pool: ?*std.Thread.Pool,
    x: Tensor,
    packed_weights: ?@import("int4_weights.zig").Int4WeightData,
    w_f32: []const f32,
    w_f16: []const f16,
    bias: []const f32,
    out: Tensor,
    out_f: usize,
    in_f: usize,
    int4_activation: Int4Activation,
) TensorError!void {
    if (packed_weights) |weights| {
        return linearInt4Decode(pool, x, weights, bias, out, out_f, in_f, int4_activation);
    }
    if (w_f16.len > 0) return dotproduct.linearF16Weight(x, w_f16, bias, out);
    return forward_linearF32Weights(x, w_f32, bias, out_f, in_f, out);
}

fn projectLinearWithExecutor(
    pool: ?*std.Thread.Pool,
    executor: ?*int4_executor.Executor,
    x: Tensor,
    packed_weights: ?@import("int4_weights.zig").Int4WeightData,
    w_f32: []const f32,
    w_f16: []const f16,
    bias: []const f32,
    out: Tensor,
    out_f: usize,
    in_f: usize,
    int4_activation: Int4Activation,
) TensorError!void {
    if (executor) |packed_executor| {
        if (packed_weights) |weights| {
            const projection = int4_executor.Projection{
                .x = x,
                .weights = weights,
                .bias = bias,
                .out = out,
                .out_f = out_f,
                .in_f = in_f,
                .use_q8 = int4_activation == .q8,
            };
            return packed_executor.run(&.{projection});
        }
    }
    return projectLinear(pool, x, packed_weights, w_f32, w_f16, bias, out, out_f, in_f, int4_activation);
}

const SiluQ8Scratch = struct {
    q_output: []i8,
    activation_scales: []f32,
};

/// Overlay Q8 values and their scale stream on the legacy f32 SwiGLU buffer.
/// Decode buffers are cache-line aligned; when capacity permits, scales start
/// on the next 64-byte boundary so the final Q8 line does not false-share with
/// the first scale writes. Small/external buffers keep the compact safe layout.
fn siluQ8Scratch(
    scratch: []f32,
    hidden: usize,
    group_size: u32,
) ?SiluQ8Scratch {
    if (group_size != 8 and group_size != 16) return null;
    const scale_count = int4_matmul.q8ActivationScaleCount(hidden, group_size);
    const compact_offset = hidden / @sizeOf(f32) +
        @intFromBool(hidden % @sizeOf(f32) != 0);
    const aligned_bytes = std.math.add(usize, hidden, 63) catch return null;
    const aligned_offset = (aligned_bytes & ~@as(usize, 63)) / @sizeOf(f32);
    const use_aligned = @intFromPtr(scratch.ptr) % 64 == 0 and
        aligned_offset <= scratch.len and scale_count <= scratch.len - aligned_offset;
    const scale_offset = if (use_aligned) aligned_offset else compact_offset;
    if (scale_offset > scratch.len or scale_count > scratch.len - scale_offset)
        return null;
    const scratch_bytes = std.mem.sliceAsBytes(scratch);
    if (hidden > scratch_bytes.len) return null;
    return .{
        .q_output = std.mem.bytesAsSlice(i8, scratch_bytes)[0..hidden],
        .activation_scales = scratch[scale_offset..][0..scale_count],
    };
}

fn pairSiluQ8Scratch(
    buffers: *decode_buffers.LayerBuffers,
    hidden: usize,
    group_size: u32,
) ?SiluQ8Scratch {
    if (buffers.pairQ8Scratch(hidden, group_size)) |compact| {
        return .{
            .q_output = compact.q_output,
            .activation_scales = compact.activation_scales,
        };
    }
    return siluQ8Scratch(buffers.silu_gate, hidden, group_size);
}

/// Try the packed QKV -> RoPE/KV -> attention -> WO -> residual/RMSNorm ->
/// gate/up graph. The executor validates every projection phase before
/// broadcasting workers, and the cache row remains logically uncommitted until
/// the outer decode graph completes every layer.
fn tryHandoffAttentionProjection(
    cfg: forward.LayerConfig,
    weights: forward.LayerWeights,
    h_norm: Tensor,
    q_row: Tensor,
    k_row: Tensor,
    v_row: Tensor,
    attn_out: Tensor,
    proj: Tensor,
    x_row: Tensor,
    h: Tensor,
    mlp_norm: Tensor,
    gate: Tensor,
    up: Tensor,
    down: Tensor,
    out_row: Tensor,
    silu_scratch: []f32,
    cache: *kv.KVCache,
    cache_layer_idx: usize,
    cur_pos: usize,
    executor: *int4_executor.Executor,
    parallel_attention_min_context: ?usize,
    parallel_attention_dispatches_out: ?*usize,
    handoff_dispatches_out: ?*usize,
    fused_gqa_dispatches_out: ?*usize,
    paired_mlp_dispatches_out: ?*usize,
    decode_plan_mode: DecodePlanMode,
    decode_plan_slot: ?*?SealedDecodeLayerPlan,
    decode_plan_telemetry: ?*DecodePlanTelemetry,
    int4_activation: Int4Activation,
    rope_table: *const RopeTable,
) GenerateError!bool {
    // The final phase consumes a bridge-prepared SwiGLU Q8 activation. The
    // packed prepared-activation kernel is currently AArch64-only; falling
    // through to the portable projection path would requantize `gate` instead
    // of consuming SiLU(gate) * up. Keep other architectures on the exact
    // serial graph until they implement that prepared-input contract.
    if (comptime builtin.cpu.arch != .aarch64) return false;
    const wq = weights.wq_int4 orelse return false;
    const wk = weights.wk_int4 orelse return false;
    const wv = weights.wv_int4 orelse return false;
    const wo = weights.wo_int4 orelse return false;
    const w_gate = weights.w_gate_int4 orelse return false;
    const w_up = weights.w_up_int4 orelse return false;
    const w_down = weights.w_down_int4 orelse return false;
    if (int4_activation != .q8 or
        (w_down.group_size != 8 and w_down.group_size != 16)) return false;
    const gate_compact = w_gate.expanded_i8.len < w_gate.num_elements;
    const up_compact = w_up.expanded_i8.len < w_up.num_elements;
    if ((w_gate.group_size != 8 and w_gate.group_size != 16) or
        w_gate.group_size != w_up.group_size or
        w_gate.packed_layout != w_up.packed_layout or
        gate_compact != up_compact or
        (gate_compact and cfg.dim > int4_executor.max_shared_input))
        return false;
    const final_scratch = siluQ8Scratch(
        silu_scratch,
        cfg.hidden_dim,
        w_down.group_size,
    ) orelse return false;
    const q_output = final_scratch.q_output;
    const activation_scales = final_scratch.activation_scales;
    const filled = cache.len;
    if (!shouldParallelizeAttention(
        filled + 1,
        cfg.num_heads,
        executor.participantCount(),
        parallel_attention_min_context,
    )) return false;

    const kv_dim = cfg.num_kv_heads * cfg.head_dim;
    if (cache_layer_idx >= cache.num_layers or cache.dim != kv_dim)
        return GenerateError.ForwardFailed;
    if (filled >= cache.max_seq) return GenerateError.CacheFull;

    var attention_plan: forward.SharedKvAttentionPlan = blk: {
        if (decode_plan_mode == .sealed_required) {
            const slot = decode_plan_slot orelse
                return GenerateError.SealedDecodePlanUnavailable;
            if (slot.*) |*layer_plan| {
                break :blk layer_plan.attention.bind(cur_pos) catch
                    return GenerateError.SealedDecodePlanUnavailable;
            }
        }

        var k_shape: [2]usize = .{ filled + 1, kv_dim };
        var v_shape: [2]usize = .{ filled + 1, kv_dim };
        const k_slice = cache.keysSliceCount(cache_layer_idx, filled + 1);
        const v_slice = cache.valuesSliceCount(cache_layer_idx, filled + 1);
        const k_view: Tensor = .{ .dtype = .f32, .shape = &k_shape, .data = std.mem.sliceAsBytes(k_slice), .allocator = std.heap.page_allocator };
        const v_view: Tensor = .{ .dtype = .f32, .shape = &v_shape, .data = std.mem.sliceAsBytes(v_slice), .allocator = std.heap.page_allocator };
        break :blk forward.SharedKvAttentionPlan.init(
            q_row,
            k_view,
            v_view,
            attn_out,
            cfg.num_heads,
            cfg.head_dim,
            cfg.num_kv_heads,
            executor.participantCount(),
        ) catch return GenerateError.ForwardFailed;
    };

    const Bridge = struct {
        q_row: Tensor,
        k_row: Tensor,
        v_row: Tensor,
        cache: *kv.KVCache,
        cache_layer_idx: usize,
        cur_pos: usize,
        num_heads: usize,
        num_kv_heads: usize,
        head_dim: usize,
        rope_table: *const RopeTable,
        generate_error: ?GenerateError = null,

        fn run(raw_context: *anyopaque) TensorError!void {
            const self: *@This() = @ptrCast(@alignCast(raw_context));
            self.rope_table.apply(
                @constCast(self.k_row.asF32Unsafe()),
                self.cur_pos,
                self.num_kv_heads,
                self.head_dim,
            );
            _ = self.cache.appendRow(
                self.cache_layer_idx,
                self.k_row.asF32Unsafe(),
                self.v_row.asF32Unsafe(),
            ) catch |err| {
                self.generate_error = switch (err) {
                    error.CacheFull => GenerateError.CacheFull,
                    else => GenerateError.ForwardFailed,
                };
                return TensorError.ShapeMismatch;
            };
            self.rope_table.apply(
                @constCast(self.q_row.asF32Unsafe()),
                self.cur_pos,
                self.num_heads,
                self.head_dim,
            );
        }
    };
    var bridge: Bridge = .{
        .q_row = q_row,
        .k_row = k_row,
        .v_row = v_row,
        .cache = cache,
        .cache_layer_idx = cache_layer_idx,
        .cur_pos = cur_pos,
        .num_heads = cfg.num_heads,
        .num_kv_heads = cfg.num_kv_heads,
        .head_dim = cfg.head_dim,
        .rope_table = rope_table,
    };
    const MlpBridge = struct {
        x_row: Tensor,
        proj: Tensor,
        h: Tensor,
        mlp_norm: Tensor,
        post_attn_norm: []const f32,
        rms_eps: f32,

        fn run(raw_context: *anyopaque) TensorError!void {
            const self: *@This() = @ptrCast(@alignCast(raw_context));
            return kernels.addRmsNormF32(
                self.x_row,
                self.proj,
                self.h,
                self.post_attn_norm,
                self.rms_eps,
                self.mlp_norm,
            );
        }
    };
    var mlp_bridge: MlpBridge = .{
        .x_row = x_row,
        .proj = proj,
        .h = h,
        .mlp_norm = mlp_norm,
        .post_attn_norm = weights.post_attn_norm,
        .rms_eps = cfg.rms_eps,
    };
    const Binding = struct {
        inline fn mix(state: u64, value: u64) u64 {
            return (state ^ value) *% 0x0000_0100_0000_01b3;
        }

        fn run(
            raw_bridge: *anyopaque,
            raw_attention: *anyopaque,
            raw_mlp_bridge: *anyopaque,
            layer_index: usize,
            position: usize,
            attention_task_count: usize,
        ) TensorError!u64 {
            const bound_bridge: *Bridge = @ptrCast(@alignCast(raw_bridge));
            const bound_attention: *forward.SharedKvAttentionPlan =
                @ptrCast(@alignCast(raw_attention));
            const bound_mlp: *MlpBridge = @ptrCast(@alignCast(raw_mlp_bridge));
            if (bound_bridge.cache_layer_idx != layer_index or
                bound_bridge.cur_pos != position or
                bound_bridge.cache.len != position or
                layer_index >= bound_bridge.cache.num_layers)
                return TensorError.ShapeMismatch;

            var key = try bound_attention.sealedBindingKey(
                position,
                attention_task_count,
            );
            key = mix(key, @intFromPtr(bound_bridge.q_row.data.ptr));
            key = mix(key, @intFromPtr(bound_bridge.k_row.data.ptr));
            key = mix(key, @intFromPtr(bound_bridge.v_row.data.ptr));
            key = mix(key, @intFromPtr(bound_bridge.cache));
            key = mix(key, @intFromPtr(bound_bridge.cache.keys[layer_index].ptr));
            key = mix(key, @intFromPtr(bound_bridge.cache.values[layer_index].ptr));
            key = mix(key, bound_bridge.num_heads);
            key = mix(key, bound_bridge.num_kv_heads);
            key = mix(key, bound_bridge.head_dim);
            key = mix(key, @intFromPtr(bound_bridge.rope_table));
            key = mix(key, @intFromPtr(bound_mlp.x_row.data.ptr));
            key = mix(key, @intFromPtr(bound_mlp.proj.data.ptr));
            key = mix(key, @intFromPtr(bound_mlp.h.data.ptr));
            key = mix(key, @intFromPtr(bound_mlp.mlp_norm.data.ptr));
            key = mix(key, @intFromPtr(bound_mlp.post_attn_norm.ptr));
            key = mix(key, bound_mlp.post_attn_norm.len);
            return mix(key, @as(u32, @bitCast(bound_mlp.rms_eps)));
        }
    };

    // Once the layer has a finalized plan, skip rebuilding all seven
    // Projection descriptors and the HandoffGraph aggregate. Only the dynamic
    // callback contexts above remain per-token state.
    if (decode_plan_mode == .sealed_required) {
        const slot = decode_plan_slot orelse
            return GenerateError.SealedDecodePlanUnavailable;
        if (slot.*) |*layer_plan| {
            executor.runSealedHandoffGraph(&layer_plan.handoff, .{
                .layer_index = cache_layer_idx,
                .position = cur_pos,
                .bridge_context = @ptrCast(&bridge),
                .attention_context = @ptrCast(&attention_plan),
                .attention_task_count = attention_plan.task_count,
                .mlp_bridge_context = @ptrCast(&mlp_bridge),
            }) catch {
                if (decode_plan_telemetry) |telemetry| telemetry.rejects += 1;
                if (bridge.generate_error) |err| return err;
                return GenerateError.ForwardFailed;
            };
            if (decode_plan_telemetry) |telemetry|
                telemetry.sealed_dispatches += 1;
            if (parallel_attention_dispatches_out) |dispatches| dispatches.* += 1;
            if (handoff_dispatches_out) |dispatches| dispatches.* += 1;
            if (attention_plan.usesFusedSharedKv()) {
                if (fused_gqa_dispatches_out) |dispatches| dispatches.* += 1;
            }
            if (paired_mlp_dispatches_out) |dispatches| dispatches.* += 1;
            addInto(out_row.asF32Unsafe(), h.asF32Unsafe(), down.asF32Unsafe());
            return true;
        }
    }
    const qkv = [_]int4_executor.Projection{
        .{ .x = h_norm, .weights = wq, .bias = weights.bq, .out = q_row, .out_f = cfg.dim, .in_f = cfg.dim, .use_q8 = int4_activation == .q8 },
        .{ .x = h_norm, .weights = wk, .bias = weights.bk, .out = k_row, .out_f = kv_dim, .in_f = cfg.dim, .use_q8 = int4_activation == .q8 },
        .{ .x = h_norm, .weights = wv, .bias = weights.bv, .out = v_row, .out_f = kv_dim, .in_f = cfg.dim, .use_q8 = int4_activation == .q8 },
    };
    const output = [_]int4_executor.Projection{
        .{ .x = attn_out, .weights = wo, .bias = weights.bo, .out = proj, .out_f = cfg.dim, .in_f = cfg.dim, .use_q8 = int4_activation == .q8 },
    };
    const mlp = [_]int4_executor.Projection{
        .{ .x = mlp_norm, .weights = w_gate, .bias = &.{}, .out = gate, .out_f = cfg.hidden_dim, .in_f = cfg.dim, .use_q8 = int4_activation == .q8 },
        .{ .x = mlp_norm, .weights = w_up, .bias = &.{}, .out = up, .out_f = cfg.hidden_dim, .in_f = cfg.dim, .use_q8 = int4_activation == .q8 },
    };
    const final = [_]int4_executor.Projection{
        .{ .x = gate, .weights = w_down, .bias = &.{}, .out = down, .out_f = cfg.dim, .in_f = cfg.hidden_dim, .use_q8 = true },
    };
    const graph: int4_executor.HandoffGraph = .{
        .qkv = &qkv,
        .bridge_context = @ptrCast(&bridge),
        .bridge = Bridge.run,
        .attention_context = @ptrCast(&attention_plan),
        .attention_task_count = attention_plan.task_count,
        .attention_task = forward.SharedKvAttentionPlan.run,
        .output = &output,
        .mlp_bridge_context = @ptrCast(&mlp_bridge),
        .mlp_bridge = MlpBridge.run,
        .mlp = &mlp,
        .final_handoff = .{ .paired_silu_q8 = .{
            .gate = gate,
            .up = up,
            .q_output = q_output,
            .activation_scales = activation_scales,
        } },
        .final = .{
            .projections = &final,
            .q_input = q_output,
            .activation_scales = activation_scales,
            .group_size = w_down.group_size,
        },
        .sealed_position = cur_pos,
        .sealed_binding = Binding.run,
    };
    switch (decode_plan_mode) {
        .checked => {
            executor.runHandoffGraph(graph) catch {
                if (bridge.generate_error) |err| return err;
                return GenerateError.ForwardFailed;
            };
            if (decode_plan_telemetry) |telemetry|
                telemetry.checked_dispatches += 1;
        },
        .sealed_required => {
            const slot = decode_plan_slot orelse
                return GenerateError.SealedDecodePlanUnavailable;
            if (slot.* == null) {
                var build_timer = std.time.Timer.start() catch unreachable;
                const handoff_plan = executor.prepareSealedHandoffPlan(
                    cache_layer_idx,
                    graph,
                ) catch {
                    if (decode_plan_telemetry) |telemetry| telemetry.rejects += 1;
                    return GenerateError.SealedDecodePlanUnavailable;
                };
                const attention_recipe =
                    forward.SealedSharedKvAttentionRecipe.init(
                        &attention_plan,
                        cache.keys[cache_layer_idx],
                        cache.values[cache_layer_idx],
                    ) catch {
                        if (decode_plan_telemetry) |telemetry| telemetry.rejects += 1;
                        return GenerateError.SealedDecodePlanUnavailable;
                    };
                slot.* = .{
                    .handoff = handoff_plan,
                    .attention = attention_recipe,
                };
                if (decode_plan_telemetry) |telemetry| telemetry.layer_builds += 1;
                const unbound = if (slot.*) |*value| &value.handoff else unreachable;
                executor.finalizeSealedHandoffPlan(unbound) catch {
                    slot.* = null;
                    if (decode_plan_telemetry) |telemetry| telemetry.rejects += 1;
                    return GenerateError.SealedDecodePlanUnavailable;
                };
                if (decode_plan_telemetry) |telemetry| {
                    telemetry.layer_binds += 1;
                    telemetry.build_ns += build_timer.read();
                }
            }
            const plan = if (slot.*) |*value| &value.handoff else unreachable;
            executor.runSealedHandoffGraph(plan, .{
                .layer_index = cache_layer_idx,
                .position = cur_pos,
                .bridge_context = @ptrCast(&bridge),
                .attention_context = @ptrCast(&attention_plan),
                .attention_task_count = attention_plan.task_count,
                .mlp_bridge_context = @ptrCast(&mlp_bridge),
            }) catch {
                if (decode_plan_telemetry) |telemetry| telemetry.rejects += 1;
                if (bridge.generate_error) |err| return err;
                return GenerateError.ForwardFailed;
            };
            if (decode_plan_telemetry) |telemetry|
                telemetry.sealed_dispatches += 1;
        },
    }
    if (parallel_attention_dispatches_out) |dispatches| dispatches.* += 1;
    if (handoff_dispatches_out) |dispatches| dispatches.* += 1;
    if (attention_plan.usesFusedSharedKv()) {
        if (fused_gqa_dispatches_out) |dispatches| dispatches.* += 1;
    }
    if (paired_mlp_dispatches_out) |dispatches| dispatches.* += 1;
    addInto(out_row.asF32Unsafe(), h.asF32Unsafe(), down.asF32Unsafe());
    return true;
}

fn forwardLayerCached(
    cfg: forward.LayerConfig,
    weights: forward.LayerWeights,
    x_row: Tensor,
    cache: *kv.KVCache,
    cache_layer_idx: usize,
    cur_pos: usize,
    bufs: *decode_buffers.LayerBuffers,
    out_row: Tensor,
    pool: ?*std.Thread.Pool,
    projection_worker: ?*ProjectionWorker,
    packed_executor: ?*int4_executor.Executor,
    parallel_attention_min_context: ?usize,
    parallel_attention_dispatches_out: ?*usize,
    handoff_dispatches_out: ?*usize,
    fused_gqa_dispatches_out: ?*usize,
    paired_mlp_dispatches_out: ?*usize,
    decode_plan_mode: DecodePlanMode,
    decode_plan_slot: ?*?SealedDecodeLayerPlan,
    decode_plan_telemetry: ?*DecodePlanTelemetry,
    mlp_representation: AdmittedMlpRepresentation,
    pair_nibble_telemetry: ?*PairNibbleExecutionTelemetry,
    pair_nibble_phase: PairNibblePhase,
    int4_activation: Int4Activation,
    rope_table: *const RopeTable,
) GenerateError!void {
    const dim = cfg.dim;
    const hidden = cfg.hidden_dim;
    const kv_dim = cfg.num_kv_heads * cfg.head_dim;

    // Stack-local shape storage for all Tensor views in this function.
    // Must stay alive for the duration of the function.
    var s_hn: [2]usize = undefined;
    var s_q: [2]usize = undefined;
    var s_k: [2]usize = undefined;
    var s_v: [2]usize = undefined;
    var s_attn: [2]usize = undefined;
    var s_proj: [2]usize = undefined;
    var s_h: [2]usize = undefined;
    var s_mlp: [2]usize = undefined;
    var s_gate: [2]usize = undefined;
    var s_up: [2]usize = undefined;
    var s_silu: [2]usize = undefined;
    var s_down: [2]usize = undefined;

    // Pre-allocated buffer views — zero allocation per token.
    // Uses f16 matmul path when f16 weights are available (halved bandwidth).
    const h_norm = decode_buffers.DecodeBuffers.view(bufs.h_norm, &s_hn, dim);
    kernels_rmsNormF32(x_row, weights.input_norm, cfg.rms_eps, h_norm) catch return GenerateError.ForwardFailed;

    const q_row = decode_buffers.DecodeBuffers.view(bufs.q, &s_q, dim);
    const k_row = decode_buffers.DecodeBuffers.view(bufs.k, &s_k, kv_dim);
    const v_row = decode_buffers.DecodeBuffers.view(bufs.v, &s_v, kv_dim);
    const attn_out = decode_buffers.DecodeBuffers.view(bufs.attn_out, &s_attn, dim);
    const proj = decode_buffers.DecodeBuffers.view(bufs.proj, &s_proj, dim);
    const h = decode_buffers.DecodeBuffers.view(bufs.h, &s_h, dim);
    const mlp_norm = decode_buffers.DecodeBuffers.view(bufs.mlp_norm, &s_mlp, dim);
    var gate: ?Tensor = null;
    var up: ?Tensor = null;
    if (mlp_representation == .separate) {
        gate = decode_buffers.DecodeBuffers.view(bufs.gate, &s_gate, hidden);
        up = decode_buffers.DecodeBuffers.view(bufs.up, &s_up, hidden);
    }
    const down = decode_buffers.DecodeBuffers.view(bufs.down, &s_down, dim);
    var pair_down_producer: ?int4_executor.PairNibbleSiluQ8Projection = null;
    var handoff_done = false;
    if (mlp_representation == .separate and
        parallel_attention_min_context != null)
    {
        if (packed_executor) |executor| {
            handoff_done = try tryHandoffAttentionProjection(
                cfg,
                weights,
                h_norm,
                q_row,
                k_row,
                v_row,
                attn_out,
                proj,
                x_row,
                h,
                mlp_norm,
                gate.?,
                up.?,
                down,
                out_row,
                bufs.silu_gate,
                cache,
                cache_layer_idx,
                cur_pos,
                executor,
                parallel_attention_min_context,
                parallel_attention_dispatches_out,
                handoff_dispatches_out,
                fused_gqa_dispatches_out,
                paired_mlp_dispatches_out,
                decode_plan_mode,
                decode_plan_slot,
                decode_plan_telemetry,
                int4_activation,
                rope_table,
            );
        }
    }
    if (decode_plan_mode == .sealed_required and !handoff_done) {
        if (decode_plan_telemetry) |telemetry| telemetry.rejects += 1;
        return GenerateError.SealedDecodePlanUnavailable;
    }
    if (!handoff_done) {
        const KVArgs = struct {
            pool: ?*std.Thread.Pool,
            x: Tensor,
            wk: []const f32,
            wk_f16: []const f16,
            bk: []const f32,
            wk_int4: ?@import("int4_weights.zig").Int4WeightData,
            wv: []const f32,
            wv_f16: []const f16,
            bv: []const f32,
            wv_int4: ?@import("int4_weights.zig").Int4WeightData,
            k: Tensor,
            v: Tensor,
            kv_dim: usize,
            dim: usize,
            activation: Int4Activation,
            err: *?TensorError,

            fn run(args: *@This()) void {
                projectLinear(args.pool, args.x, args.wk_int4, args.wk, args.wk_f16, args.bk, args.k, args.kv_dim, args.dim, args.activation) catch |err| {
                    args.err.* = err;
                    return;
                };
                projectLinear(args.pool, args.x, args.wv_int4, args.wv, args.wv_f16, args.bv, args.v, args.kv_dim, args.dim, args.activation) catch |err| {
                    args.err.* = err;
                };
            }
        };
        var kv_err: ?TensorError = null;
        var kv_args = KVArgs{
            .pool = pool,
            .x = h_norm,
            .wk = weights.wk,
            .wk_f16 = weights.wk_f16,
            .bk = weights.bk,
            .wk_int4 = weights.wk_int4,
            .wv = weights.wv,
            .wv_f16 = weights.wv_f16,
            .bv = weights.bv,
            .wv_int4 = weights.wv_int4,
            .k = k_row,
            .v = v_row,
            .kv_dim = kv_dim,
            .dim = dim,
            .activation = int4_activation,
            .err = &kv_err,
        };
        var qkv_done = false;
        if (packed_executor) |executor| {
            if (weights.wq_int4 != null and weights.wk_int4 != null and weights.wv_int4 != null) {
                const projections = [_]int4_executor.Projection{
                    .{ .x = h_norm, .weights = weights.wq_int4.?, .bias = weights.bq, .out = q_row, .out_f = dim, .in_f = dim, .use_q8 = int4_activation == .q8 },
                    .{ .x = h_norm, .weights = weights.wk_int4.?, .bias = weights.bk, .out = k_row, .out_f = kv_dim, .in_f = dim, .use_q8 = int4_activation == .q8 },
                    .{ .x = h_norm, .weights = weights.wv_int4.?, .bias = weights.bv, .out = v_row, .out_f = kv_dim, .in_f = dim, .use_q8 = int4_activation == .q8 },
                };
                executor.run(&projections) catch return GenerateError.ForwardFailed;
                qkv_done = true;
            }
        }
        const kv_runner = struct {
            fn run(ptr: *anyopaque) void {
                KVArgs.run(@ptrCast(@alignCast(ptr)));
            }
        }.run;
        var kv_thread: ?std.Thread = null;
        if (!qkv_done) {
            if (projection_worker) |worker| {
                worker.start(.{ .run = kv_runner, .args = @ptrCast(&kv_args) });
            } else {
                kv_thread = std.Thread.spawn(.{}, KVArgs.run, .{&kv_args}) catch null;
            }
            const q_result = projectLinear(pool, h_norm, weights.wq_int4, weights.wq, weights.wq_f16, weights.bq, q_row, dim, dim, int4_activation);
            if (q_result) |_| {} else |_| {
                // The worker owns stack-backed arguments; always join it before
                // returning on a validation/allocation failure in the main branch.
                if (projection_worker) |worker| worker.wait() else if (kv_thread) |thread| thread.join();
                return GenerateError.ForwardFailed;
            }
            if (projection_worker) |worker| worker.wait() else {
                if (kv_thread) |thread| thread.join();
                if (kv_thread == null) KVArgs.run(&kv_args);
            }
            if (kv_err) |_| return GenerateError.ForwardFailed;
        }

        const num_heads = cfg.num_heads;
        const head_dim = cfg.head_dim;
        const filled = cache.len;

        rope_table.apply(@constCast(k_row.asF32Unsafe()), cur_pos, cfg.num_kv_heads, head_dim);
        _ = cache.appendRow(cache_layer_idx, k_row.asF32Unsafe(), v_row.asF32Unsafe()) catch return GenerateError.CacheFull;

        var k_shape: [2]usize = .{ filled + 1, kv_dim };
        var v_shape: [2]usize = .{ filled + 1, kv_dim };
        const k_slice = cache.keysSliceCount(cache_layer_idx, filled + 1);
        const v_slice = cache.valuesSliceCount(cache_layer_idx, filled + 1);
        const k_view: Tensor = .{ .dtype = .f32, .shape = &k_shape, .data = std.mem.sliceAsBytes(k_slice), .allocator = std.heap.page_allocator };
        const v_view: Tensor = .{ .dtype = .f32, .shape = &v_shape, .data = std.mem.sliceAsBytes(v_slice), .allocator = std.heap.page_allocator };

        rope_table.apply(@constCast(q_row.asF32Unsafe()), cur_pos, num_heads, head_dim);

        if (packed_executor) |executor| {
            if (shouldParallelizeAttention(
                filled + 1,
                num_heads,
                executor.participantCount(),
                parallel_attention_min_context,
            )) {
                forward.attentionMultiHeadParallel(
                    q_row,
                    k_view,
                    v_view,
                    attn_out,
                    num_heads,
                    head_dim,
                    cfg.rope_theta,
                    cfg.num_kv_heads,
                    executor,
                ) catch return GenerateError.ForwardFailed;
                if (parallel_attention_dispatches_out) |dispatches| dispatches.* += 1;
            } else {
                forward.attentionMultiHead(q_row, k_view, v_view, attn_out, num_heads, head_dim, cfg.rope_theta, cfg.num_kv_heads) catch return GenerateError.ForwardFailed;
            }
        } else {
            forward.attentionMultiHead(q_row, k_view, v_view, attn_out, num_heads, head_dim, cfg.rope_theta, cfg.num_kv_heads) catch return GenerateError.ForwardFailed;
        }

        projectLinearWithExecutor(pool, packed_executor, attn_out, weights.wo_int4, weights.wo, weights.wo_f16, weights.bo, proj, dim, dim, int4_activation) catch return GenerateError.ForwardFailed;
    }

    if (!handoff_done) {
        addInto(h.asF32Unsafe(), x_row.asF32Unsafe(), proj.asF32Unsafe());
        kernels_rmsNormF32(h, weights.post_attn_norm, cfg.rms_eps, mlp_norm) catch return GenerateError.ForwardFailed;

        switch (mlp_representation) {
            .pair_nibble => {
                if (packed_executor == null) {
                    if (pair_nibble_telemetry) |telemetry|
                        telemetry.rejects +|= 1;
                    return GenerateError.ForwardFailed;
                }
                const pair_weights = weights.w_gate_up_pair_int4 orelse {
                    if (pair_nibble_telemetry) |telemetry|
                        telemetry.rejects +|= 1;
                    return GenerateError.ForwardFailed;
                };
                const down_weights = weights.w_down_int4 orelse {
                    if (pair_nibble_telemetry) |telemetry|
                        telemetry.rejects +|= 1;
                    return GenerateError.ForwardFailed;
                };
                if (int4_activation != .q8) {
                    if (pair_nibble_telemetry) |telemetry|
                        telemetry.rejects +|= 1;
                    return GenerateError.ForwardFailed;
                }
                const prepared = pairSiluQ8Scratch(
                    bufs,
                    hidden,
                    down_weights.group_size,
                ) orelse {
                    if (pair_nibble_telemetry) |telemetry|
                        telemetry.rejects +|= 1;
                    return GenerateError.ForwardFailed;
                };
                pair_down_producer = .{
                    .x = mlp_norm,
                    .weights = pair_weights,
                    .gate_bias = &.{},
                    .up_bias = &.{},
                    .q_output = prepared.q_output,
                    .activation_scales = prepared.activation_scales,
                    .out_f = hidden,
                    .in_f = dim,
                    .down_group_size = down_weights.group_size,
                };
            },
            .separate => {
                const UpArgs = struct {
                    pool: ?*std.Thread.Pool,
                    x: Tensor,
                    up: Tensor,
                    up_w: []const f32,
                    up_w_f16: []const f16,
                    up_int4: ?int4_weights.Int4WeightData,
                    hidden: usize,
                    dim: usize,
                    activation: Int4Activation,
                    err: *?TensorError,

                    fn run(args: *@This()) void {
                        projectLinear(args.pool, args.x, args.up_int4, args.up_w, args.up_w_f16, &.{}, args.up, args.hidden, args.dim, args.activation) catch |err| {
                            args.err.* = err;
                        };
                    }
                };
                var up_err: ?TensorError = null;
                var up_args = UpArgs{
                    .pool = pool,
                    .x = mlp_norm,
                    .up = up.?,
                    .up_w = weights.w_up,
                    .up_w_f16 = weights.w_up_f16,
                    .up_int4 = weights.w_up_int4,
                    .hidden = hidden,
                    .dim = dim,
                    .activation = int4_activation,
                    .err = &up_err,
                };
                var gate_up_done = false;
                if (packed_executor) |executor| {
                    if (weights.w_gate_int4 != null and weights.w_up_int4 != null) {
                        const projections = [_]int4_executor.Projection{
                            .{ .x = mlp_norm, .weights = weights.w_gate_int4.?, .bias = &.{}, .out = gate.?, .out_f = hidden, .in_f = dim, .use_q8 = int4_activation == .q8 },
                            .{ .x = mlp_norm, .weights = weights.w_up_int4.?, .bias = &.{}, .out = up.?, .out_f = hidden, .in_f = dim, .use_q8 = int4_activation == .q8 },
                        };
                        executor.run(&projections) catch return GenerateError.ForwardFailed;
                        gate_up_done = true;
                    }
                }
                const up_runner = struct {
                    fn run(ptr: *anyopaque) void {
                        UpArgs.run(@ptrCast(@alignCast(ptr)));
                    }
                }.run;
                var up_thread: ?std.Thread = null;
                if (!gate_up_done) {
                    if (projection_worker) |worker| {
                        worker.start(.{ .run = up_runner, .args = @ptrCast(&up_args) });
                    } else {
                        up_thread = std.Thread.spawn(.{}, UpArgs.run, .{&up_args}) catch null;
                    }
                    const gate_result = projectLinear(pool, mlp_norm, weights.w_gate_int4, weights.w_gate, weights.w_gate_f16, &.{}, gate.?, hidden, dim, int4_activation);
                    if (gate_result) |_| {} else |_| {
                        if (projection_worker) |worker| worker.wait() else if (up_thread) |thread| thread.join();
                        return GenerateError.ForwardFailed;
                    }
                    if (projection_worker) |worker| worker.wait() else {
                        if (up_thread) |thread| thread.join();
                        if (up_thread == null) UpArgs.run(&up_args);
                    }
                    if (up_err) |_| return GenerateError.ForwardFailed;
                }
            },
        }
    }

    if (!handoff_done) {
        var down_done = false;
        if (packed_executor) |executor| {
            if (weights.w_down_int4) |down_weights| {
                if (comptime builtin.cpu.arch == .aarch64) {
                    if (pair_down_producer) |producer| {
                        const projection: int4_executor.PairNibblePreparedDownProjection = .{
                            .weights = down_weights,
                            .bias = &.{},
                            .out = down,
                            .out_f = dim,
                            .in_f = hidden,
                        };
                        executor.runPairNibbleSiluQ8Down(
                            producer,
                            projection,
                        ) catch {
                            if (pair_nibble_telemetry) |telemetry|
                                telemetry.rejects +|= 1;
                            return GenerateError.ForwardFailed;
                        };
                        if (pair_nibble_telemetry) |telemetry| {
                            switch (pair_nibble_phase) {
                                .prefill => telemetry.prefill_m1_dispatches +|= 1,
                                .decode => telemetry.decode_m1_dispatches +|= 1,
                            }
                            telemetry.outputless_m1_dispatches +|= 1;
                            telemetry.activation_rows_quantized +|= 1;
                            telemetry.selected_layer_rows +|= 1;
                            telemetry.checked_dispatches +|= 1;
                        }
                        down_done = true;
                    } else if (mlp_representation == .separate and
                        int4_activation == .q8 and
                        (down_weights.group_size == 8 or down_weights.group_size == 16))
                    {
                        if (siluQ8Scratch(
                            bufs.silu_gate,
                            hidden,
                            down_weights.group_size,
                        )) |final_scratch| {
                            const q_output = final_scratch.q_output;
                            const activation_scales = final_scratch.activation_scales;
                            kernels.siluMulQuantizeQ8(
                                gate.?,
                                up.?,
                                down_weights.group_size,
                                q_output,
                                activation_scales,
                            ) catch return GenerateError.ForwardFailed;
                            const projection: int4_executor.Projection = .{
                                .x = gate.?,
                                .weights = down_weights,
                                .bias = &.{},
                                .out = down,
                                .out_f = dim,
                                .in_f = hidden,
                                .use_q8 = true,
                            };
                            executor.runPrepared(
                                &.{projection},
                                q_output,
                                activation_scales,
                                down_weights.group_size,
                            ) catch return GenerateError.ForwardFailed;
                            down_done = true;
                        }
                    }
                }
            }
        }
        if (!down_done) {
            if (mlp_representation != .separate) {
                if (pair_nibble_telemetry) |telemetry|
                    telemetry.rejects +|= 1;
                return GenerateError.ForwardFailed;
            }
            const silu_gate = decode_buffers.DecodeBuffers.view(bufs.silu_gate, &s_silu, hidden);
            kernels.siluMulF32(gate.?, up.?, silu_gate) catch return GenerateError.ForwardFailed;
            projectLinearWithExecutor(pool, packed_executor, silu_gate, weights.w_down_int4, weights.w_down, weights.w_down_f16, &.{}, down, dim, hidden, int4_activation) catch return GenerateError.ForwardFailed;
        }

        addInto(out_row.asF32Unsafe(), h.asF32Unsafe(), down.asF32Unsafe());
    }
}

fn projectPackedBatch(
    pool: *std.Thread.Pool,
    x: Tensor,
    weights: @import("int4_weights.zig").Int4WeightData,
    bias: []const f32,
    out: Tensor,
    out_f: usize,
    in_f: usize,
    q_scratch: []i8,
    scale_scratch: []f32,
    max_tasks: usize,
) GenerateError!void {
    int4_matmul.linearInt4WeightBatchQ8Parallel(
        pool,
        x,
        weights,
        bias,
        out,
        out_f,
        in_f,
        q_scratch,
        scale_scratch,
        max_tasks,
    ) catch return GenerateError.ForwardFailed;
}

/// Stream one PairNibble MLP through a bounded row capsule. The producer join
/// inside the compact kernel publishes complete Q8/SwiGLU rows; only then may
/// the prepared down projection read them. The down join completes before the
/// capsule is reused, so scratch lifetime is independent of prompt length and
/// layer count.
fn projectCompactPairMlpPackedBatch(
    pool: *std.Thread.Pool,
    mlp_norm: Tensor,
    weights: forward.LayerWeights,
    bufs: *prefill_buffers.Buffers,
    down_buffer: []f32,
    dim: usize,
    hidden: usize,
    max_tasks: usize,
    pair_nibble_telemetry: ?*PairNibbleExecutionTelemetry,
    pair_prefill_frame_telemetry: ?*PairPrefillFrameTelemetry,
) GenerateError!void {
    if (bufs.kind != .compact_pair or bufs.capsule_rows == 0 or
        bufs.tile_rows == 0 or bufs.task_slots == 0)
        return GenerateError.ForwardFailed;
    const pair_weights = weights.w_gate_up_pair_int4 orelse
        return GenerateError.ForwardFailed;
    const down_weights = weights.w_down_int4 orelse
        return GenerateError.ForwardFailed;
    const rows = mlp_norm.shape[0];
    const input = mlp_norm.asF32Unsafe();

    var capsule_start: usize = 0;
    while (capsule_start < rows) {
        const capsule_count = @min(
            bufs.capsule_rows,
            rows - capsule_start,
        );
        const input_start = std.math.mul(
            usize,
            capsule_start,
            dim,
        ) catch return GenerateError.ShapeMismatch;
        const input_count = std.math.mul(
            usize,
            capsule_count,
            dim,
        ) catch return GenerateError.ShapeMismatch;
        int4_matmul.linearPairNibbleSiluQ8CompactBatchParallel(
            pool,
            input[input_start..][0..input_count],
            capsule_count,
            pair_weights,
            &.{},
            &.{},
            bufs.q_scratch,
            bufs.scale_scratch,
            bufs.pair_q8,
            bufs.pair_scales,
            bufs.gate_tile,
            bufs.up_tile,
            down_weights.group_size,
            bufs.tile_rows,
            bufs.task_slots,
            max_tasks,
        ) catch return GenerateError.ForwardFailed;

        const down_start = std.math.mul(
            usize,
            capsule_start,
            dim,
        ) catch return GenerateError.ShapeMismatch;
        var down_shape: [2]usize = undefined;
        const down = prefill_buffers.Buffers.view(
            down_buffer[down_start..],
            &down_shape,
            capsule_count,
            dim,
        );
        int4_matmul.linearInt4WeightQ8PreparedBatchParallel(
            pool,
            bufs.pair_q8,
            bufs.pair_scales,
            down_weights,
            &.{},
            down,
            dim,
            hidden,
            max_tasks,
        ) catch return GenerateError.ForwardFailed;

        if (pair_nibble_telemetry) |telemetry| {
            telemetry.prefill_m4_groups +|= capsule_count / 4;
            if (capsule_count % 4 != 0) {
                telemetry.prefill_tail_dispatches +|= 1;
                telemetry.prefill_tail_rows +|= capsule_count % 4;
            }
            telemetry.activation_rows_quantized +|= capsule_count;
            telemetry.selected_layer_rows +|= capsule_count;
            telemetry.checked_dispatches +|= (capsule_count + 3) / 4;
        }
        if (pair_prefill_frame_telemetry) |telemetry| {
            telemetry.capsules +|= 1;
            telemetry.pair_input_rows +|= capsule_count;
            telemetry.pair_output_rows +|= capsule_count;
            telemetry.prepared_down_rows +|= capsule_count;
            telemetry.prepared_down_dispatches +|= 1;
        }
        capsule_start += capsule_count;
    }
}

/// Run one packed transformer layer over a contiguous prompt suffix. Every
/// projection is an MxK packed GEMM; K/V are bulk-written at `cache.len`, but
/// the shared logical length advances only after all layers finish the chunk.
fn forwardLayerPackedBatch(
    cfg: forward.LayerConfig,
    weights: forward.LayerWeights,
    x: Tensor,
    cache: *kv.KVCache,
    cache_layer_idx: usize,
    absolute_start: usize,
    bufs: *prefill_buffers.Buffers,
    out: Tensor,
    pool: *std.Thread.Pool,
    max_tasks: usize,
    mlp_representation: AdmittedMlpRepresentation,
    pair_nibble_telemetry: ?*PairNibbleExecutionTelemetry,
    pair_prefill_frame_policy: PairPrefillFramePolicy,
    pair_prefill_frame_telemetry: ?*PairPrefillFrameTelemetry,
    rope_table: *const RopeTable,
) GenerateError!void {
    const rows = x.shape[0];
    const dim = cfg.dim;
    const hidden = cfg.hidden_dim;
    const kv_dim = cfg.num_kv_heads * cfg.head_dim;
    if (rows == 0 or x.shape.len != 2 or x.shape[1] != dim or
        out.shape.len != 2 or out.shape[0] != rows or out.shape[1] != dim)
        return GenerateError.ShapeMismatch;

    const wq = weights.wq_int4 orelse return GenerateError.ForwardFailed;
    const wk = weights.wk_int4 orelse return GenerateError.ForwardFailed;
    const wv = weights.wv_int4 orelse return GenerateError.ForwardFailed;
    const wo = weights.wo_int4 orelse return GenerateError.ForwardFailed;
    const w_down = weights.w_down_int4 orelse return GenerateError.ForwardFailed;

    var s_hn: [2]usize = undefined;
    var s_q: [2]usize = undefined;
    var s_k: [2]usize = undefined;
    var s_v: [2]usize = undefined;
    var s_attn: [2]usize = undefined;
    var s_proj: [2]usize = undefined;
    var s_h: [2]usize = undefined;
    var s_mlp: [2]usize = undefined;
    var s_gate: [2]usize = undefined;
    var s_up: [2]usize = undefined;
    var s_silu: [2]usize = undefined;
    var s_down: [2]usize = undefined;

    const h_norm = prefill_buffers.Buffers.view(bufs.h_norm, &s_hn, rows, dim);
    kernels.rmsNormF32(x, weights.input_norm, cfg.rms_eps, h_norm) catch
        return GenerateError.ForwardFailed;

    const q_rows = prefill_buffers.Buffers.view(bufs.q, &s_q, rows, dim);
    const k_rows = prefill_buffers.Buffers.view(bufs.k, &s_k, rows, kv_dim);
    const v_rows = prefill_buffers.Buffers.view(bufs.v, &s_v, rows, kv_dim);
    try projectPackedBatch(pool, h_norm, wq, weights.bq, q_rows, dim, dim, bufs.q_scratch, bufs.scale_scratch, max_tasks);
    try projectPackedBatch(pool, h_norm, wk, weights.bk, k_rows, kv_dim, dim, bufs.q_scratch, bufs.scale_scratch, max_tasks);
    try projectPackedBatch(pool, h_norm, wv, weights.bv, v_rows, kv_dim, dim, bufs.q_scratch, bufs.scale_scratch, max_tasks);

    for (0..rows) |row| {
        rope_table.apply(
            q_rows.asF32Unsafe()[row * dim ..][0..dim],
            absolute_start + row,
            cfg.num_heads,
            cfg.head_dim,
        );
        rope_table.apply(
            k_rows.asF32Unsafe()[row * kv_dim ..][0..kv_dim],
            absolute_start + row,
            cfg.num_kv_heads,
            cfg.head_dim,
        );
    }
    _ = cache.appendRows(
        cache_layer_idx,
        k_rows.asF32Unsafe(),
        v_rows.asF32Unsafe(),
        rows,
    ) catch return GenerateError.CacheFull;

    const kv_count = absolute_start + rows;
    var k_shape: [2]usize = .{ kv_count, kv_dim };
    var v_shape: [2]usize = .{ kv_count, kv_dim };
    const k_view: Tensor = .{
        .dtype = .f32,
        .shape = &k_shape,
        .data = std.mem.sliceAsBytes(cache.keysSliceCount(cache_layer_idx, kv_count)),
        .allocator = std.heap.page_allocator,
    };
    const v_view: Tensor = .{
        .dtype = .f32,
        .shape = &v_shape,
        .data = std.mem.sliceAsBytes(cache.valuesSliceCount(cache_layer_idx, kv_count)),
        .allocator = std.heap.page_allocator,
    };
    const attn_out = prefill_buffers.Buffers.view(bufs.attn_out, &s_attn, rows, dim);
    forward.attentionMultiHead(
        q_rows,
        k_view,
        v_view,
        attn_out,
        cfg.num_heads,
        cfg.head_dim,
        cfg.rope_theta,
        cfg.num_kv_heads,
    ) catch return GenerateError.ForwardFailed;

    const proj = prefill_buffers.Buffers.view(bufs.proj, &s_proj, rows, dim);
    try projectPackedBatch(pool, attn_out, wo, weights.bo, proj, dim, dim, bufs.q_scratch, bufs.scale_scratch, max_tasks);
    const h = prefill_buffers.Buffers.view(bufs.h, &s_h, rows, dim);
    addInto(h.asF32Unsafe(), x.asF32Unsafe(), proj.asF32Unsafe());

    const mlp_norm = prefill_buffers.Buffers.view(bufs.mlp_norm, &s_mlp, rows, dim);
    kernels.rmsNormF32(h, weights.post_attn_norm, cfg.rms_eps, mlp_norm) catch
        return GenerateError.ForwardFailed;
    var materialized_mlp = true;
    switch (mlp_representation) {
        .separate => {
            if (pair_prefill_frame_policy != .disabled or
                bufs.kind != .materialized)
                return GenerateError.ForwardFailed;
            const gate = prefill_buffers.Buffers.view(
                bufs.gate,
                &s_gate,
                rows,
                hidden,
            );
            const up = prefill_buffers.Buffers.view(
                bufs.up,
                &s_up,
                rows,
                hidden,
            );
            const w_gate = weights.w_gate_int4 orelse
                return GenerateError.ForwardFailed;
            const w_up = weights.w_up_int4 orelse
                return GenerateError.ForwardFailed;
            try projectPackedBatch(pool, mlp_norm, w_gate, &.{}, gate, hidden, dim, bufs.q_scratch, bufs.scale_scratch, max_tasks);
            try projectPackedBatch(pool, mlp_norm, w_up, &.{}, up, hidden, dim, bufs.q_scratch, bufs.scale_scratch, max_tasks);
        },
        .pair_nibble => {
            const pair_weights = weights.w_gate_up_pair_int4 orelse {
                if (pair_nibble_telemetry) |telemetry|
                    telemetry.rejects +|= 1;
                return GenerateError.ForwardFailed;
            };
            switch (pair_prefill_frame_policy) {
                .materialized => {
                    if (bufs.kind != .materialized)
                        return GenerateError.ForwardFailed;
                    const gate = prefill_buffers.Buffers.view(
                        bufs.gate,
                        &s_gate,
                        rows,
                        hidden,
                    );
                    const up = prefill_buffers.Buffers.view(
                        bufs.up,
                        &s_up,
                        rows,
                        hidden,
                    );
                    int4_matmul.linearPairNibbleWeightBatchQ8Parallel(
                        pool,
                        mlp_norm,
                        pair_weights,
                        &.{},
                        &.{},
                        gate,
                        up,
                        hidden,
                        dim,
                        bufs.q_scratch,
                        bufs.scale_scratch,
                        max_tasks,
                    ) catch {
                        if (pair_nibble_telemetry) |telemetry|
                            telemetry.rejects +|= 1;
                        return GenerateError.ForwardFailed;
                    };
                    if (pair_nibble_telemetry) |telemetry| {
                        telemetry.prefill_m4_groups +|= rows / 4;
                        if (rows % 4 != 0) {
                            telemetry.prefill_tail_dispatches +|= 1;
                            telemetry.prefill_tail_rows +|= rows % 4;
                        }
                        telemetry.activation_rows_quantized +|= rows;
                        telemetry.selected_layer_rows +|= rows;
                        telemetry.checked_dispatches +|= (rows + 3) / 4;
                    }
                    if (pair_prefill_frame_telemetry) |telemetry| {
                        telemetry.materialized_layer_uses +|= 1;
                        telemetry.pair_input_rows +|= rows;
                        telemetry.pair_output_rows +|= rows;
                    }
                },
                .compact_32, .compact_64 => {
                    materialized_mlp = false;
                    try projectCompactPairMlpPackedBatch(
                        pool,
                        mlp_norm,
                        weights,
                        bufs,
                        bufs.down,
                        dim,
                        hidden,
                        max_tasks,
                        pair_nibble_telemetry,
                        pair_prefill_frame_telemetry,
                    );
                    if (pair_prefill_frame_telemetry) |telemetry|
                        telemetry.compact_layer_uses +|= 1;
                },
                .disabled => return GenerateError.ForwardFailed,
            }
        },
    }

    if (materialized_mlp) {
        const gate = prefill_buffers.Buffers.view(
            bufs.gate,
            &s_gate,
            rows,
            hidden,
        );
        const up = prefill_buffers.Buffers.view(
            bufs.up,
            &s_up,
            rows,
            hidden,
        );
        const silu_gate = prefill_buffers.Buffers.view(
            bufs.silu_gate,
            &s_silu,
            rows,
            hidden,
        );
        kernels.siluMulF32(gate, up, silu_gate) catch
            return GenerateError.ForwardFailed;
        const down = prefill_buffers.Buffers.view(
            bufs.down,
            &s_down,
            rows,
            dim,
        );
        try projectPackedBatch(
            pool,
            silu_gate,
            w_down,
            &.{},
            down,
            dim,
            hidden,
            bufs.q_scratch,
            bufs.scale_scratch,
            max_tasks,
        );
    }

    const down_count = std.math.mul(usize, rows, dim) catch
        return GenerateError.ShapeMismatch;
    addInto(
        out.asF32Unsafe(),
        h.asF32Unsafe(),
        bufs.down[0..down_count],
    );
}

fn packedBatchWeightSupported(
    maybe_weights: ?@import("int4_weights.zig").Int4WeightData,
    out_f: usize,
    in_f: usize,
) bool {
    const weights = maybe_weights orelse return false;
    const expected = std.math.mul(usize, out_f, in_f) catch return false;
    if (weights.num_elements != expected or weights.packed_layout != .rows4_k16 or
        (weights.group_size != 8 and weights.group_size != 16) or
        out_f % 4 != 0 or in_f % 16 != 0)
        return false;
    const scale_count = (expected + weights.group_size - 1) / weights.group_size;
    return weights.packed_bytes.len >= (expected + 1) / 2 and
        weights.scales_f16_rows4.len >= scale_count;
}

/// The outputless Pair epoch consumes only the compact rows4 stream. Reject a
/// co-resident expanded image during request admission so strict Pair mode
/// cannot allocate successfully and then fail at its first M1 layer.
fn pairDownWeightSupported(
    maybe_weights: ?@import("int4_weights.zig").Int4WeightData,
    out_f: usize,
    in_f: usize,
) bool {
    const weights = maybe_weights orelse return false;
    return weights.expanded_i8.len == 0 and
        packedBatchWeightSupported(weights, out_f, in_f);
}

fn pairNibbleWeightSupported(
    maybe_weights: ?int4_weights.PairNibbleWeightData,
    out_f: usize,
    in_f: usize,
) bool {
    const weights = maybe_weights orelse return false;
    if (weights.out_f != out_f or weights.in_f != in_f or
        weights.num_elements_per_branch != std.math.mul(
            usize,
            out_f,
            in_f,
        ) catch return false)
        return false;
    int4_weights.validatePairNibble(weights) catch return false;
    return true;
}

fn checkedResidentBytes(comptime T: type, values: []const T) ?usize {
    return std.math.mul(usize, values.len, @sizeOf(T)) catch null;
}

fn checkedAddResidentBytes(total: *usize, amount: usize) bool {
    total.* = std.math.add(usize, total.*, amount) catch return false;
    return true;
}

fn accountSingleInt4ResidentBytes(
    total: *usize,
    maybe_weights: ?int4_weights.Int4WeightData,
) bool {
    const weights = maybe_weights orelse return true;
    const streams = [_]usize{
        weights.packed_bytes.len,
        checkedResidentBytes(f32, weights.scales) orelse return false,
        checkedResidentBytes(f16, weights.scales_f16) orelse return false,
        checkedResidentBytes(f16, weights.scales_f16_rows4) orelse return false,
        checkedResidentBytes(i8, weights.expanded_i8) orelse return false,
    };
    for (streams) |amount| {
        if (!checkedAddResidentBytes(total, amount)) return false;
    }
    return true;
}

fn accountSeparateBranchBytes(
    total: *usize,
    raw: []const f32,
    half: []const f16,
    packed_weights: ?int4_weights.Int4WeightData,
) bool {
    if (!checkedAddResidentBytes(
        total,
        checkedResidentBytes(f32, raw) orelse return false,
    ) or !checkedAddResidentBytes(
        total,
        checkedResidentBytes(f16, half) orelse return false,
    )) return false;
    return accountSingleInt4ResidentBytes(total, packed_weights);
}

fn rejectMlpRepresentation(options: GenerateOptions) GenerateError {
    if (options.pair_nibble_telemetry) |telemetry|
        telemetry.rejects +|= 1;
    return GenerateError.MlpRepresentationUnavailable;
}

fn rejectPairScratch(options: GenerateOptions) GenerateError {
    if (options.pair_scratch_telemetry) |telemetry|
        telemetry.rejects +|= 1;
    return GenerateError.MlpRepresentationUnavailable;
}

fn rejectPairPrefillFrame(options: GenerateOptions) GenerateError {
    if (options.pair_prefill_frame_telemetry) |telemetry|
        telemetry.rejects +|= 1;
    return GenerateError.BatchPrefillUnavailable;
}

fn pairPrefillFrameRequired(options: GenerateOptions) bool {
    return options.pair_prefill_frame_mode != .automatic;
}

fn recordPairScratchTelemetry(
    destination: ?*PairScratchExecutionTelemetry,
    snapshot: int4_executor.PairScratchTelemetry,
) void {
    const telemetry = destination orelse return;
    const ledger = snapshot.ledger;
    telemetry.selected_policy = snapshot.policy;
    telemetry.participants = ledger.participants;
    telemetry.selected_g8_rows = ledger.selected_g8_rows;
    telemetry.selected_g16_rows = ledger.selected_g16_rows;
    telemetry.capacity_rows = ledger.capacity_rows;
    telemetry.branch_stride_rows = ledger.branch_stride_rows;
    telemetry.participant_stride_rows = ledger.participant_stride_rows;
    telemetry.f32_elements = ledger.f32_elements;
    telemetry.bytes = ledger.bytes;
    telemetry.fixed_counterfactual_bytes = ledger.fixed_counterfactual_bytes;
    telemetry.reclaimed_bytes = ledger.reclaimed_bytes;
    telemetry.allocations = snapshot.allocations;
    telemetry.fixed_dispatches = snapshot.fixed_dispatches;
    telemetry.model_shaped_dispatches = snapshot.model_shaped_dispatches;
}

/// PairNibble's retained executor schedule is certified for at most eight
/// participants. Keep this check separate from executor construction so an
/// unsupported many-core request is rejected before executor, KV-cache, or
/// request-buffer allocation.
fn pairNibbleParticipantsSupported(
    representation: AdmittedMlpRepresentation,
    participants: usize,
) bool {
    return representation != .pair_nibble or
        (participants >= 1 and participants <= 8);
}

/// Validate one immutable request-level MLP representation before KV cache,
/// activation, executor, or output allocation. Pair admission is deliberately
/// stricter than the compatibility path: it requires a prepared homogeneous
/// image, exact rows4/K16 geometry, Q8, and the persistent checked executor.
fn admitMlpRepresentation(
    model: loader.LoadedModel,
    options: GenerateOptions,
) GenerateError!AdmittedMlpRepresentation {
    const telemetry = options.pair_nibble_telemetry;
    var pair_layers: usize = 0;
    var pair_weight_bytes: usize = 0;
    var pair_scale_bytes: usize = 0;
    var separate_gate_bytes: usize = 0;
    var separate_up_bytes: usize = 0;
    var down_g8_layers: usize = 0;
    var down_g16_layers: usize = 0;
    var producer_g8_layers: usize = 0;
    var producer_g16_layers: usize = 0;

    for (model.layers) |layer| {
        if (!accountSeparateBranchBytes(
            &separate_gate_bytes,
            layer.w_gate,
            layer.w_gate_f16,
            layer.w_gate_int4,
        ) or !accountSeparateBranchBytes(
            &separate_up_bytes,
            layer.w_up,
            layer.w_up_f16,
            layer.w_up_int4,
        )) return rejectMlpRepresentation(options);
        if (layer.w_gate_up_pair_int4) |pair| {
            pair_layers += 1;
            switch (pair.group_size) {
                8 => producer_g8_layers += 1,
                16 => producer_g16_layers += 1,
                else => {},
            }
            if (!checkedAddResidentBytes(&pair_weight_bytes, pair.paired_bytes.len) or
                !checkedAddResidentBytes(
                    &pair_scale_bytes,
                    checkedResidentBytes(f16, pair.scales_f16_pairs) orelse
                        return rejectMlpRepresentation(options),
                )) return rejectMlpRepresentation(options);
        }
        if (layer.w_down_int4) |down| {
            switch (down.group_size) {
                8 => down_g8_layers += 1,
                16 => down_g16_layers += 1,
                else => {},
            }
        }
    }
    if (telemetry) |value| {
        value.artifact_layers = pair_layers;
        value.pair_weight_bytes = pair_weight_bytes;
        value.pair_scale_bytes = pair_scale_bytes;
        value.separate_gate_bytes = separate_gate_bytes;
        value.separate_up_bytes = separate_up_bytes;
        value.down_g8_layers = down_g8_layers;
        value.down_g16_layers = down_g16_layers;
    }
    if (options.pair_scratch_telemetry) |value| {
        value.producer_g8_layers = producer_g8_layers;
        value.producer_g16_layers = producer_g16_layers;
    }
    if (options.pair_prefill_frame_telemetry) |value| {
        value.producer_g8_layers = producer_g8_layers;
        value.producer_g16_layers = producer_g16_layers;
        value.down_g8_layers = down_g8_layers;
        value.down_g16_layers = down_g16_layers;
    }

    switch (options.mlp_representation) {
        .separate => {
            if (pair_layers != 0 or
                model.prepared_mlp_layout == .pair_nibble)
                return rejectMlpRepresentation(options);
            return .separate;
        },
        .pair_nibble_required => {
            if (comptime builtin.cpu.arch != .aarch64)
                return rejectMlpRepresentation(options);
            if (model.prepared_mlp_layout != .pair_nibble or
                pair_layers != model.layers.len or model.layers.len == 0 or
                separate_gate_bytes != 0 or separate_up_bytes != 0 or
                options.int4_activation != .q8 or
                !options.use_persistent_executor or
                options.decode_plan_mode != .checked)
                return rejectMlpRepresentation(options);

            const cfg = model.config;
            if (cfg.dim > int4_executor.max_shared_input or
                cfg.hidden_dim > int4_executor.max_shared_input)
                return rejectMlpRepresentation(options);
            const kv_dim = std.math.mul(
                usize,
                cfg.num_kv_heads,
                cfg.head_dim,
            ) catch return rejectMlpRepresentation(options);
            if (!packedBatchWeightSupported(
                model.token_embedding_int4,
                cfg.vocab_size,
                cfg.dim,
            ) or !packedBatchWeightSupported(
                model.lm_head_int4,
                cfg.vocab_size,
                cfg.dim,
            )) return rejectMlpRepresentation(options);
            for (model.layers) |layer| {
                if (!pairNibbleWeightSupported(
                    layer.w_gate_up_pair_int4,
                    cfg.hidden_dim,
                    cfg.dim,
                ) or !packedBatchWeightSupported(
                    layer.wq_int4,
                    cfg.dim,
                    cfg.dim,
                ) or !packedBatchWeightSupported(
                    layer.wk_int4,
                    kv_dim,
                    cfg.dim,
                ) or !packedBatchWeightSupported(
                    layer.wv_int4,
                    kv_dim,
                    cfg.dim,
                ) or !packedBatchWeightSupported(
                    layer.wo_int4,
                    cfg.dim,
                    cfg.dim,
                ) or !pairDownWeightSupported(
                    layer.w_down_int4,
                    cfg.dim,
                    cfg.hidden_dim,
                )) return rejectMlpRepresentation(options);
            }
            if (telemetry) |value| {
                value.admissions = 1;
                value.selected_layers = model.layers.len;
            }
            return .pair_nibble;
        },
    }
}

fn compactPairFrameKind(
    model: loader.LoadedModel,
    options: GenerateOptions,
) GenerateError!decode_buffers.MlpFrameKind {
    var saw_down = false;
    var needs_g16 = false;
    for (model.layers) |layer| {
        const down = layer.w_down_int4 orelse
            return rejectMlpRepresentation(options);
        saw_down = true;
        switch (down.group_size) {
            8 => {},
            16 => needs_g16 = true,
            else => return rejectMlpRepresentation(options),
        }
    }
    if (!saw_down) return rejectMlpRepresentation(options);
    return if (needs_g16) .compact_pair_g16 else .compact_pair_g8;
}

/// Resolve frame geometry immediately after representation admission and before
/// executor, KV-cache, logits, or activation allocation. A required compact
/// frame can therefore never degrade to the materialized compatibility frame.
fn selectDecodeFrameKind(
    model: loader.LoadedModel,
    representation: AdmittedMlpRepresentation,
    options: GenerateOptions,
) GenerateError!decode_buffers.MlpFrameKind {
    return switch (options.decode_frame_mode) {
        .automatic => switch (representation) {
            .separate => .materialized,
            .pair_nibble => compactPairFrameKind(model, options),
        },
        .materialized_required => .materialized,
        .compact_pair_required => if (representation == .pair_nibble)
            compactPairFrameKind(model, options)
        else
            rejectMlpRepresentation(options),
    };
}

fn admittedPairProducerGroups(
    model: loader.LoadedModel,
    options: GenerateOptions,
) GenerateError!int4_executor.PairGroupSet {
    var groups: int4_executor.PairGroupSet = .{};
    for (model.layers) |layer| {
        const pair = layer.w_gate_up_pair_int4 orelse
            return rejectPairScratch(options);
        switch (pair.group_size) {
            8 => groups.g8 = true,
            16 => groups.g16 = true,
            else => return rejectPairScratch(options),
        }
    }
    if (!groups.g8 and !groups.g16) return rejectPairScratch(options);
    return groups;
}

/// Resolve Pair scratch before executor, KV, logits, or frame allocation. The
/// producer-group set is independent from the down groups used by frame sizing.
fn selectPairScratchSpec(
    model: loader.LoadedModel,
    representation: AdmittedMlpRepresentation,
    options: GenerateOptions,
) GenerateError!int4_executor.PairScratchSpec {
    return switch (options.pair_scratch_mode) {
        .automatic => switch (representation) {
            .separate => .{},
            .pair_nibble => .{
                .policy = .fixed_256,
                .producer_groups = try admittedPairProducerGroups(model, options),
            },
        },
        .fixed_256_required => if (representation == .pair_nibble)
            .{
                .policy = .fixed_256,
                .producer_groups = try admittedPairProducerGroups(model, options),
            }
        else
            rejectPairScratch(options),
        .model_shaped_required => if (representation == .pair_nibble)
            .{
                .policy = .model_shaped,
                .producer_groups = try admittedPairProducerGroups(model, options),
            }
        else
            rejectPairScratch(options),
    };
}

/// Resolve the complete prompt-MLP representation before request allocation.
/// Automatic deliberately leaves separate models disabled and admitted Pair
/// models on the materialized control until replicated PP128/512/2K evidence
/// promotes one compact capsule. Every required arm is Pair-only and fail
/// closed, so a benchmark cannot silently time another implementation.
fn selectPairPrefillFramePolicy(
    representation: AdmittedMlpRepresentation,
    options: GenerateOptions,
) GenerateError!PairPrefillFramePolicy {
    const selected: PairPrefillFramePolicy = switch (options.pair_prefill_frame_mode) {
        .automatic => switch (representation) {
            .separate => .disabled,
            .pair_nibble => .materialized,
        },
        .materialized_required => if (representation == .pair_nibble)
            .materialized
        else
            return rejectPairPrefillFrame(options),
        .compact_32_required => if (representation == .pair_nibble)
            .compact_32
        else
            return rejectPairPrefillFrame(options),
        .compact_64_required => if (representation == .pair_nibble)
            .compact_64
        else
            return rejectPairPrefillFrame(options),
    };
    if (options.pair_prefill_frame_telemetry) |telemetry|
        telemetry.selected_policy = selected;
    return selected;
}

fn modelSupportsPackedBatch(
    model: loader.LoadedModel,
    mlp_representation: AdmittedMlpRepresentation,
) bool {
    if (comptime builtin.cpu.arch != .aarch64) return false;
    const cfg = model.config;
    const kv_dim = cfg.num_kv_heads * cfg.head_dim;
    for (model.layers) |layer| {
        const down_supported = switch (mlp_representation) {
            .separate => packedBatchWeightSupported(
                layer.w_down_int4,
                cfg.dim,
                cfg.hidden_dim,
            ),
            .pair_nibble => pairDownWeightSupported(
                layer.w_down_int4,
                cfg.dim,
                cfg.hidden_dim,
            ),
        };
        if (!packedBatchWeightSupported(layer.wq_int4, cfg.dim, cfg.dim) or
            !packedBatchWeightSupported(layer.wk_int4, kv_dim, cfg.dim) or
            !packedBatchWeightSupported(layer.wv_int4, kv_dim, cfg.dim) or
            !packedBatchWeightSupported(layer.wo_int4, cfg.dim, cfg.dim) or
            !down_supported)
            return false;
        switch (mlp_representation) {
            .separate => if (!packedBatchWeightSupported(
                layer.w_gate_int4,
                cfg.hidden_dim,
                cfg.dim,
            ) or !packedBatchWeightSupported(
                layer.w_up_int4,
                cfg.hidden_dim,
                cfg.dim,
            )) return false,
            .pair_nibble => if (!pairNibbleWeightSupported(
                layer.w_gate_up_pair_int4,
                cfg.hidden_dim,
                cfg.dim,
            )) return false,
        }
    }
    return true;
}

fn sealedWeightSupported(
    maybe_weights: ?@import("int4_weights.zig").Int4WeightData,
    out_f: usize,
    in_f: usize,
) bool {
    const weights = maybe_weights orelse return false;
    return packedBatchWeightSupported(weights, out_f, in_f) and
        weights.expanded_i8.len < weights.num_elements;
}

fn modelSupportsSealedDecode(model: loader.LoadedModel) bool {
    if (comptime builtin.cpu.arch != .aarch64) return false;
    const cfg = model.config;
    const kv_dim = cfg.num_kv_heads * cfg.head_dim;
    for (model.layers) |layer| {
        if (!sealedWeightSupported(layer.wq_int4, cfg.dim, cfg.dim) or
            !sealedWeightSupported(layer.wk_int4, kv_dim, cfg.dim) or
            !sealedWeightSupported(layer.wv_int4, kv_dim, cfg.dim) or
            !sealedWeightSupported(layer.wo_int4, cfg.dim, cfg.dim) or
            !sealedWeightSupported(layer.w_gate_int4, cfg.hidden_dim, cfg.dim) or
            !sealedWeightSupported(layer.w_up_int4, cfg.hidden_dim, cfg.dim) or
            !sealedWeightSupported(layer.w_down_int4, cfg.dim, cfg.hidden_dim))
            return false;
    }
    return true;
}

const packed_prefill_min_tokens: usize = 8;
const packed_prefill_chunk_rows: usize = 256;
const compact_pair_prefill_tile_rows: usize = 64;

fn checkedQ8ScaleStride(in_f: usize, group_size: u32) ?usize {
    const activation_group: usize = switch (group_size) {
        8 => 32,
        16 => 16,
        else => return null,
    };
    return in_f / activation_group +
        @intFromBool(in_f % activation_group != 0);
}

/// Derive the one request-local frame from admitted immutable weights. Compact
/// mode reserves only the largest input-scale stride actually used by this
/// model, rather than the materialized control's historical H/8 bound.
fn pairPrefillBufferSpec(
    model: loader.LoadedModel,
    policy: PairPrefillFramePolicy,
    chunk_capacity: usize,
    max_tasks: usize,
) GenerateError!prefill_buffers.Spec {
    const cfg = model.config;
    const kv_dim = std.math.mul(
        usize,
        cfg.num_kv_heads,
        cfg.head_dim,
    ) catch return GenerateError.ShapeMismatch;
    const max_in = @max(cfg.dim, cfg.hidden_dim);
    const materialized_stride = max_in / 8 +
        @intFromBool(max_in % 8 != 0);
    switch (policy) {
        .disabled, .materialized => return admitPairPrefillBufferSpec(.{
            .kind = .materialized,
            .max_batch = chunk_capacity,
            .dim = cfg.dim,
            .kv_dim = kv_dim,
            .hidden = cfg.hidden_dim,
            .max_scale_stride = materialized_stride,
        }),
        .compact_32, .compact_64 => {},
    }

    if (cfg.hidden_dim < compact_pair_prefill_tile_rows)
        return GenerateError.ForwardFailed;
    var producer_scale_stride: usize = 0;
    var pair_scale_stride: usize = 0;
    for (model.layers) |layer| {
        const common = [_]?int4_weights.Int4WeightData{
            layer.wq_int4,
            layer.wk_int4,
            layer.wv_int4,
            layer.wo_int4,
        };
        for (common) |maybe_weight| {
            const weight = maybe_weight orelse
                return GenerateError.ForwardFailed;
            producer_scale_stride = @max(
                producer_scale_stride,
                checkedQ8ScaleStride(cfg.dim, weight.group_size) orelse
                    return GenerateError.ForwardFailed,
            );
        }
        const pair = layer.w_gate_up_pair_int4 orelse
            return GenerateError.ForwardFailed;
        producer_scale_stride = @max(
            producer_scale_stride,
            checkedQ8ScaleStride(cfg.dim, pair.group_size) orelse
                return GenerateError.ForwardFailed,
        );
        const down = layer.w_down_int4 orelse
            return GenerateError.ForwardFailed;
        pair_scale_stride = @max(
            pair_scale_stride,
            checkedQ8ScaleStride(cfg.hidden_dim, down.group_size) orelse
                return GenerateError.ForwardFailed,
        );
    }
    if (producer_scale_stride == 0 or pair_scale_stride == 0)
        return GenerateError.ForwardFailed;

    const requested_capsule_rows: usize = switch (policy) {
        .compact_32 => 32,
        .compact_64 => 64,
        else => unreachable,
    };
    const bounded_rows = @min(requested_capsule_rows, chunk_capacity);
    const capsule_rows = (bounded_rows / 4) * 4;
    if (capsule_rows == 0) return GenerateError.ForwardFailed;
    return admitPairPrefillBufferSpec(.{
        .kind = .compact_pair,
        .max_batch = chunk_capacity,
        .dim = cfg.dim,
        .kv_dim = kv_dim,
        .hidden = cfg.hidden_dim,
        .max_scale_stride = producer_scale_stride,
        .task_slots = max_tasks,
        .capsule_rows = capsule_rows,
        .tile_rows = compact_pair_prefill_tile_rows,
        .pair_scale_stride = pair_scale_stride,
    });
}

/// Complete every checked size/shape calculation while admission is still
/// allocation-free. `Buffers.initWithSpec` repeats this defensive check, but
/// a strict request must report the Pair-frame rejection before unrelated
/// executor, KV, logits, decode-frame, or RoPE allocation can fail first.
fn admitPairPrefillBufferSpec(
    spec: prefill_buffers.Spec,
) GenerateError!prefill_buffers.Spec {
    _ = spec.logicalLedger() catch return GenerateError.ForwardFailed;
    return spec;
}

fn resourceMul(left: usize, right: usize) GenerateError!usize {
    return std.math.mul(usize, left, right) catch
        GenerateError.ResourceAdmissionUnavailable;
}

fn resourceAdd(left: usize, right: usize) GenerateError!usize {
    return std.math.add(usize, left, right) catch
        GenerateError.ResourceAdmissionUnavailable;
}

fn resourceU64(value: usize) GenerateError!u64 {
    return std.math.cast(u64, value) orelse
        GenerateError.ResourceAdmissionUnavailable;
}

/// Derive the complete in-scope v1 execution-lifetime maximum without
/// allocating or consulting allocator state. The bound is conservative where
/// optional batch prefill or output shrinking may fall back: storage that can
/// coexist is charged together.
fn deriveRequestResourceClaim(
    model: loader.LoadedModel,
    options: GenerateOptions,
    max_kv_positions: usize,
    decode_threads: usize,
    decode_frame_kind: decode_buffers.MlpFrameKind,
    pair_scratch_spec: int4_executor.PairScratchSpec,
    prefill_frame_spec: ?prefill_buffers.Spec,
    batch_prefill_eligible: bool,
    packed_graph: bool,
    packed_executor_required: bool,
    require_greedy_scratch: bool,
) GenerateError!resource_bank.Claim {
    const cfg = model.config;
    const kv_dim = resourceMul(cfg.num_kv_heads, cfg.head_dim) catch
        return GenerateError.ResourceAdmissionUnavailable;
    const kv_ledger = kv.deriveLogicalLedger(
        cfg.num_layers,
        kv_dim,
        max_kv_positions,
    ) catch return GenerateError.ResourceAdmissionUnavailable;
    const decode_ledger = decode_buffers.deriveLogicalLedger(
        cfg.num_layers,
        cfg.dim,
        kv_dim,
        cfg.hidden_dim,
        decode_frame_kind,
    ) catch return GenerateError.ResourceAdmissionUnavailable;

    var activation_bytes = decode_ledger.tensor_payload_bytes;
    // x_row is a separately owned [1, dim] tensor with one rank-2 shape copy.
    activation_bytes = try resourceAdd(
        activation_bytes,
        try resourceMul(cfg.dim, @sizeOf(f32)),
    );
    activation_bytes = try resourceAdd(
        activation_bytes,
        2 * @sizeOf(usize),
    );
    if (batch_prefill_eligible) {
        const spec = prefill_frame_spec orelse
            return GenerateError.ResourceAdmissionUnavailable;
        const ledger = spec.logicalLedger() catch
            return GenerateError.ResourceAdmissionUnavailable;
        activation_bytes = try resourceAdd(
            activation_bytes,
            ledger.tensor_storage_bytes,
        );
    }
    var capsule_bytes: usize = 0;
    if (packed_executor_required) {
        if (!packed_graph) return GenerateError.ResourceAdmissionUnavailable;
        const executor_ledger = int4_executor.deriveExecutorLogicalLedger(
            decode_threads,
            .{
                .greedy_argmax = require_greedy_scratch,
                .pair_scratch = pair_scratch_spec,
            },
        ) catch return GenerateError.ResourceAdmissionUnavailable;
        capsule_bytes = try resourceAdd(
            capsule_bytes,
            executor_ledger.worker_thread_handles_bytes,
        );
        activation_bytes = try resourceAdd(
            activation_bytes,
            executor_ledger.pair_scratch.bytes,
        );
        activation_bytes = try resourceAdd(
            activation_bytes,
            executor_ledger.greedy_argmax_bytes,
        );
    }

    if (options.decode_plan_mode == .sealed_required) {
        capsule_bytes = try resourceAdd(
            capsule_bytes,
            try resourceMul(decode_plan_slot_bytes, cfg.num_layers),
        );
    }

    var logits_bytes: usize = 0;
    if (options.greedy_output_mode != .domain_prehead_required) {
        logits_bytes = try resourceAdd(
            try resourceMul(cfg.vocab_size, @sizeOf(f32)),
            2 * @sizeOf(usize),
        );
    }

    var partial_bytes: usize = 0;
    if (options.eligible_vocabulary_provider != null) {
        const words = try resourceAdd(
            cfg.vocab_size / 64,
            @intFromBool(cfg.vocab_size % 64 != 0),
        );
        partial_bytes = try resourceMul(words, 2 * @sizeOf(u64));
    }
    if (options.forced_tokens.len == 0 and
        options.sampler.temperature != 0)
    {
        partial_bytes = try resourceAdd(
            partial_bytes,
            try resourceMul(cfg.vocab_size, @sizeOf(sampling.Candidate)),
        );
    }

    const rope_pairs = try resourceMul(max_kv_positions, cfg.head_dim / 2);
    const rope_tables = try resourceMul(rope_pairs, 2);
    const staging_bytes = try resourceMul(rope_tables, @sizeOf(f32));
    const primary_output_journal_bytes = try resourceMul(
        options.max_new_tokens,
        @sizeOf(u32),
    );
    // Early EOS first attempts an in-place shrink. If that allocator operation
    // fails, `finishGeneratedSlice` temporarily owns an exact replacement next
    // to the original journal. The largest such replacement is max_new - 1.
    const shrink_fallback_bytes = try resourceMul(
        options.max_new_tokens -| 1,
        @sizeOf(u32),
    );
    const output_journal_bytes = try resourceAdd(
        primary_output_journal_bytes,
        shrink_fallback_bytes,
    );

    const claim: resource_bank.Claim = .{
        .capsule_bytes = try resourceU64(capsule_bytes),
        .kv_bytes = try resourceU64(kv_ledger.allocation_payload_bytes),
        .activation_bytes = try resourceU64(activation_bytes),
        .partial_bytes = try resourceU64(partial_bytes),
        .logits_bytes = try resourceU64(logits_bytes),
        .output_journal_bytes = try resourceU64(output_journal_bytes),
        .staging_bytes = try resourceU64(staging_bytes),
        .queue_slots = 1,
    };
    _ = claim.hostBytes() catch
        return GenerateError.ResourceAdmissionUnavailable;
    return claim;
}

fn hashResourceU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashStateU32(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u32,
) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hash.update(&bytes);
}

/// Canonical digest over exactly `positions` complete KV rows. Ordinary
/// callers pass `cache.len`; a transaction coordinator may pass the target of
/// a fully written private RowTxn mark while preparing terminal evidence.
/// This function never publishes or advances the cache cursor.
pub fn logicalKvPrefixSha256(
    cache: *kv.KVCache,
    positions: usize,
) [32]u8 {
    std.debug.assert(positions <= cache.max_seq);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-logical-kv-state-v1\x00");
    hashResourceU64(&hash, @intCast(cache.num_layers));
    hashResourceU64(&hash, @intCast(cache.dim));
    hashResourceU64(&hash, @intCast(positions));
    for (0..cache.num_layers) |layer| {
        const count = positions * cache.dim;
        for (cache.keysSliceCount(layer, positions)[0..count]) |value|
            hashStateU32(&hash, @bitCast(value));
        for (cache.valuesSliceCount(layer, positions)[0..count]) |value|
            hashStateU32(&hash, @bitCast(value));
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

/// Canonical digest of the logical, committed KV prefix. Allocation slack,
/// descriptors, and uncommitted tail rows are excluded.
pub fn logicalKvSha256(cache: *kv.KVCache) [32]u8 {
    return logicalKvPrefixSha256(cache, cache.len);
}

/// Canonical digest for a valid zero-position logical KV state. Generation
/// can complete without allocating a cache when `max_new_tokens == 0`; this
/// receipt keeps that state distinguishable from missing telemetry while
/// preserving the exact domain used by `logicalKvSha256`.
pub fn emptyLogicalKvSha256(num_layers: usize, dim: usize) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-logical-kv-state-v1\x00");
    hashResourceU64(&hash, @intCast(num_layers));
    hashResourceU64(&hash, @intCast(dim));
    hashResourceU64(&hash, 0);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

pub fn tokenSequenceSha256(tokens: []const u32) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-output-token-state-v1\x00");
    hashResourceU64(&hash, @intCast(tokens.len));
    for (tokens) |token| hashStateU32(&hash, token);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

/// Canonical output digest for a private prospective append. The caller's
/// journal remains unchanged until its enclosing transaction commits.
pub fn tokenSequenceAppendedSha256(
    committed_prefix: []const u32,
    appended_token: u32,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-output-token-state-v1\x00");
    hashResourceU64(&hash, @intCast(committed_prefix.len + 1));
    for (committed_prefix) |token| hashStateU32(&hash, token);
    hashStateU32(&hash, appended_token);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

pub fn recordCompletedGenerationState(
    telemetry: ?*GenerationStateTelemetry,
    cache: *kv.KVCache,
    tokens: []const u32,
    sampling_calls: usize,
    rng_prng: *const std.Random.DefaultPrng,
) void {
    const out = telemetry orelse return;
    out.* = .{
        .complete = true,
        .kv_positions = cache.len,
        .published_tokens = tokens.len,
        .sampling_calls = sampling_calls,
        .kv_sha256 = logicalKvSha256(cache),
        .output_sha256 = tokenSequenceSha256(tokens),
        .rng_state = rng_prng.s,
    };
}

/// Stable owner identity for one admitted execution capsule. The receipt also
/// binds the complete claim, so this key focuses on model/input/policy state.
fn requestResourceOwnerKey(
    model: loader.LoadedModel,
    prompt: []const u32,
    options: GenerateOptions,
    decode_threads: usize,
    decode_frame_kind: decode_buffers.MlpFrameKind,
    pair_scratch_spec: int4_executor.PairScratchSpec,
    pair_prefill_policy: PairPrefillFramePolicy,
) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-request-resource-owner-v1\x00");
    hash.update(&model.source_fingerprint);
    hashResourceU64(&hash, request_resource_bank_abi);
    hashResourceU64(&hash, @intCast(prompt.len));
    for (prompt) |token| hashResourceU64(&hash, token);
    hashResourceU64(&hash, @intCast(options.max_new_tokens));
    hashResourceU64(&hash, @intCast(decode_threads));
    hashResourceU64(&hash, @intFromEnum(decode_frame_kind));
    hashResourceU64(&hash, @intFromEnum(pair_scratch_spec.policy));
    hashResourceU64(&hash, @intFromEnum(pair_prefill_policy));
    hashResourceU64(&hash, @intFromEnum(options.int4_activation));
    hashResourceU64(&hash, @intFromEnum(options.mlp_representation));
    hashResourceU64(&hash, @intFromEnum(options.decode_frame_mode));
    hashResourceU64(&hash, @intFromEnum(options.pair_scratch_mode));
    hashResourceU64(&hash, @intFromEnum(options.pair_prefill_frame_mode));
    hashResourceU64(&hash, @intFromEnum(options.greedy_output_mode));
    hashResourceU64(&hash, @intFromEnum(options.decode_plan_mode));
    hashResourceU64(
        &hash,
        @as(u32, @bitCast(options.sampler.temperature)),
    );
    hashResourceU64(&hash, @intCast(options.sampler.top_k));
    hashResourceU64(&hash, @as(u32, @bitCast(options.sampler.top_p)));
    hashResourceU64(&hash, options.seed);
    hashResourceU64(&hash, options.eos_token);
    hashResourceU64(&hash, @intFromBool(options.use_persistent_executor));
    hashResourceU64(&hash, @intFromBool(options.use_batch_prefill));
    hashResourceU64(&hash, @intFromBool(options.require_batch_prefill));
    hashResourceU64(&hash, if (options.parallel_attention_min_context) |value|
        @intCast(value)
    else
        std.math.maxInt(u64));
    hashResourceU64(&hash, @intCast(options.forced_tokens.len));
    for (options.forced_tokens) |token| hashResourceU64(&hash, token);
    if (options.eligible_vocabulary_provider) |provider| {
        hashResourceU64(&hash, 1);
        hashResourceU64(&hash, provider.abi);
        hashResourceU64(&hash, provider.generation_epoch);
        hash.update(&provider.head_binding);
        hash.update(&provider.tokenizer_binding);
        hash.update(&provider.policy_binding);
    } else {
        hashResourceU64(&hash, 0);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const owner = std.mem.readInt(u64, digest[0..8], .little);
    return if (owner == 0) 1 else owner;
}

fn recordRequestResourceTelemetry(
    telemetry: ?*RequestResourceTelemetry,
    bank: *resource_bank.Bank,
    claim: ?resource_bank.Claim,
    owner_key: u64,
    receipt: ?resource_bank.Receipt,
) void {
    const out = telemetry orelse return;
    if (claim) |value| {
        out.owner_key = owner_key;
        out.host_claim_bytes = value.hostBytes() catch 0;
        out.capsule_bytes = value.capsule_bytes;
        out.kv_bytes = value.kv_bytes;
        out.activation_bytes = value.activation_bytes;
        out.partial_bytes = value.partial_bytes;
        out.logits_bytes = value.logits_bytes;
        out.output_journal_bytes = value.output_journal_bytes;
        out.staging_bytes = value.staging_bytes;
        out.device_bytes = value.device_bytes;
        out.io_bytes = value.io_bytes;
        out.queue_slots = value.queue_slots;
    }
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

fn mapResourceBankError(err: resource_bank.Error) GenerateError {
    return switch (err) {
        error.CapacityExceeded => GenerateError.ResourceBudgetExceeded,
        else => GenerateError.ResourceAdmissionUnavailable,
    };
}

/// Validate and synchronously publish one committed receipt to the shared
/// evidence ABI. Callback errors are deliberately collapsed to the one
/// fail-closed generation error used by M1 and DecodeLane4.
pub fn runResourceCommitObserver(
    observer: ResourceCommitObserver,
    receipt: resource_bank.Receipt,
) GenerateError!void {
    if (observer.abi != resource_commit_observer_abi)
        return GenerateError.ResourceCommitObserverRejected;
    const evidence: ResourceCommitEvidenceV1 = .{ .receipt = receipt };
    observer.observe(observer.context, &evidence) catch
        return GenerateError.ResourceCommitObserverRejected;
}

/// Publish one journaled token through the versioned runner ABI. Callback and
/// ABI failures collapse to a single generation error so callers cannot time
/// a request whose event stream is incomplete.
pub fn runTokenPublicationObserver(
    observer: TokenPublicationObserver,
    step_index: usize,
    token_id: u32,
    terminal: bool,
) GenerateError!void {
    if (observer.abi != token_publication_observer_abi)
        return GenerateError.TokenPublicationObserverRejected;
    const evidence: TokenPublicationEvidenceV1 = .{
        .logical_request_index = observer.logical_request_index,
        .step_index = std.math.cast(u64, step_index) orelse
            return GenerateError.TokenPublicationObserverRejected,
        .token_id = token_id,
        .terminal = terminal,
    };
    observer.observe(observer.context, &evidence) catch
        return GenerateError.TokenPublicationObserverRejected;
}

/// Fully packed Q8 prompt path. Scratch and worker threads are request-local
/// and are released before autoregressive decode starts. A caller may safely
/// reset the cache and retry serially if this optimization returns an error.
fn runPackedBatchPrefill(
    allocator: std.mem.Allocator,
    model: loader.LoadedModel,
    prompt: []const u32,
    layer_cfg: forward.LayerConfig,
    cache: *kv.KVCache,
    final_hidden_out: Tensor,
    rope_table: *const RopeTable,
    max_tasks: usize,
    request_ready_telemetry: ?RequestReadyTelemetry,
    phase_telemetry: ?*GenerationPhaseTelemetry,
    mlp_representation: AdmittedMlpRepresentation,
    pair_nibble_telemetry: ?*PairNibbleExecutionTelemetry,
    pair_prefill_frame_policy: PairPrefillFramePolicy,
    pair_prefill_frame_telemetry: ?*PairPrefillFrameTelemetry,
    frame_spec: prefill_buffers.Spec,
) GenerateError!void {
    if (prompt.len < packed_prefill_min_tokens or max_tasks < 2)
        return GenerateError.ShapeMismatch;

    const cfg = model.config;
    const chunk_capacity = @min(prompt.len, packed_prefill_chunk_rows);
    var bufs = prefill_buffers.Buffers.initWithSpec(
        allocator,
        frame_spec,
    ) catch |err| {
        if (err == error.OutOfMemory) return GenerateError.OutOfMemory;
        return GenerateError.ForwardFailed;
    };
    defer bufs.deinit();

    if (pair_prefill_frame_telemetry) |telemetry| {
        const ledger = bufs.logicalLedger();
        const breakdown = ledger.breakdown;
        telemetry.chunk_capacity = chunk_capacity;
        telemetry.capsule_rows = bufs.capsule_rows;
        telemetry.tile_rows = bufs.tile_rows;
        telemetry.task_slots = bufs.task_slots;
        telemetry.common_payload_bytes = std.math.add(
            usize,
            breakdown.common_dim_f32_bytes,
            breakdown.common_kv_f32_bytes,
        ) catch return GenerateError.ForwardFailed;
        telemetry.gate_bytes = breakdown.gate_bytes;
        telemetry.up_bytes = breakdown.up_bytes;
        telemetry.silu_bytes = breakdown.silu_gate_bytes;
        telemetry.q_scratch_bytes = breakdown.q_scratch_bytes;
        telemetry.scale_scratch_bytes = breakdown.scale_scratch_bytes;
        telemetry.pair_q8_bytes = breakdown.pair_q8_bytes;
        telemetry.pair_scale_bytes = breakdown.pair_scale_bytes;
        telemetry.gate_tile_bytes = breakdown.gate_tile_bytes;
        telemetry.up_tile_bytes = breakdown.up_tile_bytes;
        telemetry.tensor_payload_bytes = ledger.tensor_storage_bytes;
        telemetry.materialized_counterfactual_bytes =
            ledger.materialized_counterfactual_bytes;
        telemetry.reclaimed_tensor_payload_bytes = ledger.reclaimed_bytes;
        telemetry.arena_sets = 1;
        telemetry.logical_slices = switch (bufs.kind) {
            .materialized => 16,
            .compact_pair => 17,
        };
    }

    var pool: std.Thread.Pool = undefined;
    pool.init(.{
        .allocator = std.heap.c_allocator,
        .n_jobs = max_tasks - 1,
    }) catch return GenerateError.ForwardFailed;
    defer pool.deinit();

    if (request_ready_telemetry) |telemetry| {
        telemetry.elapsed_ns_out.* = telemetry.process_timer.read();
    }
    var phase_timer: ?std.time.Timer = null;
    if (phase_telemetry != null) {
        phase_timer = std.time.Timer.start() catch unreachable;
    }

    var chunk_start: usize = 0;
    while (chunk_start < prompt.len) {
        const rows = @min(chunk_capacity, prompt.len - chunk_start);
        if (pair_prefill_frame_telemetry) |telemetry| {
            telemetry.chunk_count +|= 1;
            telemetry.peak_active_rows = @max(
                telemetry.peak_active_rows,
                rows,
            );
            if (rows == chunk_capacity)
                telemetry.full_chunks +|= 1
            else
                telemetry.tail_chunks +|= 1;
        }
        const active_count = std.math.mul(usize, rows, cfg.dim) catch
            return GenerateError.ShapeMismatch;
        var current = bufs.x[0..active_count];
        var next = bufs.next[0..active_count];
        for (prompt[chunk_start .. chunk_start + rows], 0..) |token, row| {
            try loadEmbeddingRow(
                model,
                token,
                current[row * cfg.dim ..][0..cfg.dim],
            );
        }

        for (model.layers, 0..) |weights, layer_idx| {
            var x_shape: [2]usize = undefined;
            var out_shape: [2]usize = undefined;
            const x = prefill_buffers.Buffers.view(current, &x_shape, rows, cfg.dim);
            const out = prefill_buffers.Buffers.view(next, &out_shape, rows, cfg.dim);
            try forwardLayerPackedBatch(
                layer_cfg,
                weights,
                x,
                cache,
                layer_idx,
                chunk_start,
                &bufs,
                out,
                &pool,
                max_tasks,
                mlp_representation,
                pair_nibble_telemetry,
                pair_prefill_frame_policy,
                pair_prefill_frame_telemetry,
                rope_table,
            );
            const swap = current;
            current = next;
            next = swap;
        }
        cache.commitRows(rows);

        if (chunk_start + rows == prompt.len) {
            var last_shape: [2]usize = undefined;
            const last_offset = (rows - 1) * cfg.dim;
            const last_hidden = prefill_buffers.Buffers.view(
                current[last_offset..],
                &last_shape,
                1,
                cfg.dim,
            );
            kernels.rmsNormF32(last_hidden, model.final_norm, cfg.rms_eps, final_hidden_out) catch
                return GenerateError.ForwardFailed;
        }
        chunk_start += rows;
    }
    if (phase_telemetry) |telemetry| {
        const elapsed = phase_timer.?.read();
        telemetry.prefill_graph_ns = elapsed;
        telemetry.prefill_ns = elapsed;
    }
}

fn linearInt4Decode(
    pool: ?*std.Thread.Pool,
    x: Tensor,
    weights: @import("int4_weights.zig").Int4WeightData,
    bias: []const f32,
    out: Tensor,
    out_f: usize,
    in_f: usize,
    int4_activation: Int4Activation,
) TensorError!void {
    // M1 crossover measured during the 2026-07-18 Qwen benchmark: below
    // 2^19 logical weights, worker coordination costs more than it saves.
    // The caller also helps drain the pool. Keep two work chunks per
    // participant so heterogeneous cores can rebalance the remaining shards.
    const parallel_min_elements = 1 << 18;
    if (pool) |thread_pool| {
        if (weights.num_elements >= parallel_min_elements) {
            const parallel_max_tasks = @min((thread_pool.threads.len + 1) * 2, 16);
            return switch (int4_activation) {
                .q8 => int4_matmul.linearInt4WeightParallelQ8(
                    thread_pool,
                    x,
                    weights,
                    bias,
                    out,
                    out_f,
                    in_f,
                    parallel_max_tasks,
                ),
                .f32 => int4_matmul.linearInt4WeightParallel(
                    thread_pool,
                    x,
                    weights,
                    bias,
                    out,
                    out_f,
                    in_f,
                    parallel_max_tasks,
                ),
            };
        }
    }
    return switch (int4_activation) {
        .q8 => int4_matmul.linearInt4WeightQ8(x, weights, bias, out, out_f, in_f),
        .f32 => int4_matmul.linearInt4Weight(x, weights, bias, out, out_f, in_f),
    };
}

// Thin local re-exports so the file reads like self-contained code.
const kernels = @import("backends/cpu/kernels.zig");

/// Apply RoPE to a single Q/K row at a specific absolute position.
/// Same rotation as forward.applyRopeInPlace but for one row at position
/// `pos`, used by the cached decode path where we only have the new token.
fn applyRopeSingleRow(row: []f32, pos: usize, num_heads: usize, head_dim: usize, rope_theta: f32) void {
    var h: usize = 0;
    while (h < num_heads) : (h += 1) {
        const head_off = h * head_dim;
        var k_pair: usize = 0;
        while (k_pair < head_dim / 2) : (k_pair += 1) {
            const freq = 1.0 / std.math.pow(f32, rope_theta, @as(f32, @floatFromInt(2 * k_pair)) / @as(f32, @floatFromInt(head_dim)));
            const angle = @as(f32, @floatFromInt(pos)) * freq;
            const cos_a = std.math.cos(angle);
            const sin_a = std.math.sin(angle);
            const idx0 = head_off + k_pair;
            const idx1 = head_off + k_pair + head_dim / 2;
            const x0 = row[idx0];
            const x1 = row[idx1];
            row[idx0] = x0 * cos_a - x1 * sin_a;
            row[idx1] = x0 * sin_a + x1 * cos_a;
        }
    }
}
fn kernels_rmsNormF32(x: Tensor, w: []const f32, eps: f32, out: Tensor) TensorError!void {
    return kernels.rmsNormF32(x, w, eps, out);
}
fn kernels_siluF32(x: Tensor, out: Tensor) TensorError!void {
    return kernels.siluF32(x, out);
}
fn forward_linearF32Weights(x: Tensor, w: []const f32, bias: []const f32, out_f: usize, in_f: usize, out: Tensor) TensorError!void {
    _ = out_f;
    _ = in_f;
    // Use the ILP-optimized matmul (2 rows at a time, 16-lane SIMD)
    // for the decode path where it matters most.
    const w_view: Tensor = .{
        .dtype = .f32,
        .shape = &.{ out.shape[1], x.shape[1] },
        .data = @constCast(std.mem.sliceAsBytes(w)),
        .allocator = std.heap.page_allocator,
    };
    return f16_matmul.linearF16Fast(x, w_view, bias, out);
}

inline fn addInto(dst: []f32, a: []const f32, b: []const f32) void {
    var i: usize = 0;
    while (i < dst.len) : (i += 1) dst[i] = a[i] + b[i];
}

inline fn mulInto(dst: []f32, a: []const f32, b: []const f32) void {
    var i: usize = 0;
    while (i < dst.len) : (i += 1) dst[i] = a[i] * b[i];
}

fn loadEmbeddingRow(model: loader.LoadedModel, token: u32, out: []f32) GenerateError!void {
    const cfg = model.config;
    if (token >= cfg.vocab_size) return GenerateError.ShapeMismatch;
    const row = token;
    if (model.token_embedding_int4) |int4_data| {
        int4_matmul.dequantizeRow(int4_data, row, cfg.dim, out) catch return GenerateError.ForwardFailed;
        return;
    }
    if (model.token_embedding.len < cfg.vocab_size * cfg.dim) return GenerateError.ForwardFailed;
    @memcpy(out, model.token_embedding[@as(usize, row) * cfg.dim .. (@as(usize, row) + 1) * cfg.dim]);
}

fn projectLmHead(
    model: loader.LoadedModel,
    hidden: Tensor,
    logits: Tensor,
    pool: ?*std.Thread.Pool,
    packed_executor: ?*int4_executor.Executor,
    int4_activation: Int4Activation,
) GenerateError!void {
    const cfg = model.config;
    if (model.lm_head_int4) |int4_data| {
        if (packed_executor) |executor| {
            const projection = int4_executor.Projection{
                .x = hidden,
                .weights = int4_data,
                .bias = &.{},
                .out = logits,
                .out_f = cfg.vocab_size,
                .in_f = cfg.dim,
                .use_q8 = int4_activation == .q8,
            };
            executor.run(&.{projection}) catch return GenerateError.ForwardFailed;
        } else {
            linearInt4Decode(pool, hidden, int4_data, &.{}, logits, cfg.vocab_size, cfg.dim, int4_activation) catch
                return GenerateError.ForwardFailed;
        }
        return;
    }
    forward.linearF32Weights(hidden, model.lm_head, &.{}, cfg.vocab_size, cfg.dim, logits) catch
        return GenerateError.ForwardFailed;
}

fn modelSupportsLogitlessGreedy(
    model: loader.LoadedModel,
    mlp_representation: AdmittedMlpRepresentation,
) bool {
    if (comptime builtin.cpu.arch != .aarch64) return false;
    const cfg = model.config;
    const weights = model.lm_head_int4 orelse return false;
    if (!modelSupportsPackedBatch(model, mlp_representation) or
        cfg.vocab_size == 0 or std.math.cast(u32, cfg.vocab_size - 1) == null or
        cfg.dim == 0 or
        cfg.vocab_size % 4 != 0 or cfg.dim % 16 != 0 or
        cfg.dim > int4_executor.max_shared_input or
        (weights.group_size != 8 and weights.group_size != 16) or
        cfg.dim % weights.group_size != 0 or
        weights.packed_layout != .rows4_k16 or
        weights.expanded_i8.len != 0)
        return false;
    const expected = std.math.mul(usize, cfg.vocab_size, cfg.dim) catch
        return false;
    if (weights.num_elements != expected) return false;
    return weights.packed_bytes.len >= expected / 2 and
        weights.scales_f16_rows4.len >= expected / weights.group_size;
}

fn hashEligibilityInt(
    hash: *std.crypto.hash.sha2.Sha256,
    comptime T: type,
    value: T,
) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hash.update(&bytes);
}

/// Stable provenance/geometry binding for the LM-head representation admitted
/// by the eligible producer. Its content strength inherits the loader's source
/// fingerprint contract; the remaining fields prevent reinterpreting that
/// identity with different geometry, packing, quantization, or execution ABIs.
pub fn eligibilityHeadBinding(model: loader.LoadedModel) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-eligible-lm-head-binding-v1\x00");
    hash.update(&model.source_fingerprint);
    hashEligibilityInt(&hash, u64, @intCast(model.config.vocab_size));
    hashEligibilityInt(&hash, u64, @intCast(model.config.dim));
    hashEligibilityInt(
        &hash,
        u8,
        @intFromBool(model.config.tie_word_embeddings),
    );
    hashEligibilityInt(&hash, u64, eligibility_provider_abi);
    hashEligibilityInt(&hash, u64, int4_executor.greedy_eligibility_abi);
    if (model.lm_head_int4) |weights| {
        hashEligibilityInt(&hash, u8, 1);
        hashEligibilityInt(&hash, u32, weights.group_size);
        hashEligibilityInt(
            &hash,
            u8,
            @intCast(@intFromEnum(weights.packed_layout)),
        );
        hashEligibilityInt(&hash, u64, @intCast(weights.num_elements));
        hashEligibilityInt(&hash, u64, @intCast(weights.packed_bytes.len));
        hashEligibilityInt(
            &hash,
            u64,
            @intCast(weights.scales_f16_rows4.len),
        );
        hashEligibilityInt(&hash, u64, @intCast(weights.expanded_i8.len));
    } else {
        hashEligibilityInt(&hash, u8, 0);
        hashEligibilityInt(&hash, u64, @intCast(model.lm_head.len));
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

/// Domain-separated, endian-stable digest used by provider certificates.
pub fn eligibilityMaskSha256(words: []const u64) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-eligible-mask-v1\x00");
    hashEligibilityInt(&hash, u64, @intCast(words.len));
    for (words) |word| hashEligibilityInt(&hash, u64, word);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn initialEligibilityPrefixSha256(prompt: []const u32) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-eligible-prefix-chain-v1\x00initial\x00");
    hashEligibilityInt(&hash, u64, @intCast(prompt.len));
    for (prompt) |token| hashEligibilityInt(&hash, u32, token);
    hashEligibilityInt(&hash, u64, 0);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn extendEligibilityPrefixSha256(
    previous: [32]u8,
    token: u32,
    generated_count: usize,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-eligible-prefix-chain-v1\x00append\x00");
    hash.update(&previous);
    hashEligibilityInt(&hash, u64, @intCast(generated_count));
    hashEligibilityInt(&hash, u32, token);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

var next_eligibility_request_nonce = std.atomic.Value(u64).init(1);

fn reserveEligibilityRequestNonce() GenerateError!u64 {
    var current = next_eligibility_request_nonce.load(.monotonic);
    while (true) {
        if (current == std.math.maxInt(u64)) return GenerateError.OutOfMemory;
        if (next_eligibility_request_nonce.cmpxchgWeak(
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

fn isDomainOutputMode(mode: GreedyOutputMode) bool {
    return mode == .domain_posthead_required or
        mode == .domain_prehead_required;
}

fn isZeroDigest(digest: *const [32]u8) bool {
    for (digest) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn validEligibilityWords(words: []const u64, vocab_size: usize) ?usize {
    const expected_words = vocab_size / 64 +
        @intFromBool(vocab_size % 64 != 0);
    if (expected_words == 0 or words.len != expected_words) return null;
    if (vocab_size % 64 != 0) {
        const tail_bits: u6 = @intCast(vocab_size % 64);
        const valid_tail = (@as(u64, 1) << tail_bits) - 1;
        if (words[words.len - 1] & ~valid_tail != 0) return null;
    }
    var rows: usize = 0;
    for (words) |word| {
        rows = std.math.add(usize, rows, @popCount(word)) catch return null;
    }
    if (rows == 0 or rows > vocab_size) return null;
    return rows;
}

const EligibilityState = struct {
    allocator: std.mem.Allocator,
    provider: EligibleVocabularyProvider,
    request_nonce: u64,
    prefix_sha256: [32]u8,
    generated_prefix_len: usize,
    head_binding: [32]u8,
    vocab_size: usize,
    staging_words: []u64,
    sealed_words: []u64,
    trace: ?std.crypto.hash.sha2.Sha256,
    telemetry: ?*EligibilityTelemetry,

    fn init(
        allocator: std.mem.Allocator,
        provider: EligibleVocabularyProvider,
        head_binding: [32]u8,
        vocab_size: usize,
        prompt: []const u32,
        telemetry: ?*EligibilityTelemetry,
    ) GenerateError!EligibilityState {
        const word_count = vocab_size / 64 +
            @intFromBool(vocab_size % 64 != 0);
        if (word_count == 0) return GenerateError.EligibilityCertificateRejected;
        const request_nonce = try reserveEligibilityRequestNonce();
        var prefix_timer: ?std.time.Timer = null;
        if (telemetry != null)
            prefix_timer = std.time.Timer.start() catch unreachable;
        const prefix_sha256 = initialEligibilityPrefixSha256(prompt);
        const prefix_elapsed = if (prefix_timer) |*timer| timer.read() else 0;
        const staging = allocator.alloc(u64, word_count) catch
            return GenerateError.OutOfMemory;
        errdefer allocator.free(staging);
        const sealed = allocator.alloc(u64, word_count) catch
            return GenerateError.OutOfMemory;
        errdefer allocator.free(sealed);
        @memset(staging, 0);
        @memset(sealed, 0);

        var trace: ?std.crypto.hash.sha2.Sha256 = null;
        if (telemetry != null) {
            trace = std.crypto.hash.sha2.Sha256.init(.{});
            if (trace) |*hash| {
                hash.update("glacier-eligible-trace-v1\x00");
                hashEligibilityInt(hash, u64, eligibility_provider_abi);
                hashEligibilityInt(
                    hash,
                    u64,
                    int4_executor.greedy_eligibility_abi,
                );
                hash.update(&head_binding);
                hash.update(&provider.tokenizer_binding);
                hash.update(&provider.policy_binding);
                hashEligibilityInt(hash, u64, provider.generation_epoch);
                hashEligibilityInt(hash, u64, @intCast(vocab_size));
            }
        }

        if (telemetry) |out| {
            const mask_bytes = std.math.mul(
                usize,
                word_count,
                @sizeOf(u64),
            ) catch return GenerateError.OutOfMemory;
            out.staging_mask_bytes = mask_bytes;
            out.sealed_mask_bytes = mask_bytes;
            out.request_nonce = request_nonce;
            out.verification_ns = prefix_elapsed;
        }
        return .{
            .allocator = allocator,
            .provider = provider,
            .request_nonce = request_nonce,
            .prefix_sha256 = prefix_sha256,
            .generated_prefix_len = 0,
            .head_binding = head_binding,
            .vocab_size = vocab_size,
            .staging_words = staging,
            .sealed_words = sealed,
            .trace = trace,
            .telemetry = telemetry,
        };
    }

    fn deinit(self: *EligibilityState) void {
        if (self.telemetry) |telemetry| {
            if (self.trace) |*trace| trace.final(&telemetry.trace_sha256);
        }
        self.allocator.free(self.sealed_words);
        self.allocator.free(self.staging_words);
    }

    fn reject(self: *EligibilityState, err: GenerateError) GenerateError {
        if (self.telemetry) |telemetry| telemetry.rejects +|= 1;
        return err;
    }

    fn addUsize(
        self: *EligibilityState,
        counter: *usize,
        value: usize,
    ) GenerateError!void {
        counter.* = std.math.add(usize, counter.*, value) catch
            return self.reject(GenerateError.EligibilityCertificateRejected);
    }

    fn addNs(
        self: *EligibilityState,
        counter: *u64,
        value: u64,
    ) GenerateError!void {
        counter.* = std.math.add(u64, counter.*, value) catch
            return self.reject(GenerateError.EligibilityCertificateRejected);
    }

    fn prepare(
        self: *EligibilityState,
        step_index: usize,
        logits_position: usize,
        prompt: []const u32,
        generated_prefix: []const u32,
    ) GenerateError!usize {
        const step_u64 = std.math.cast(u64, step_index) orelse
            return self.reject(GenerateError.EligibilityCertificateRejected);
        const position_u64 = std.math.cast(u64, logits_position) orelse
            return self.reject(GenerateError.EligibilityCertificateRejected);
        if (step_index != self.generated_prefix_len or
            generated_prefix.len != self.generated_prefix_len)
            return self.reject(GenerateError.EligibilityCertificateRejected);
        const prefix_sha256 = self.prefix_sha256;
        @memset(self.staging_words, 0);
        var certificate: EligibilityCertificateV1 = .{};
        const step: EligibilityStepV1 = .{
            .generation_epoch = self.provider.generation_epoch,
            .request_nonce = self.request_nonce,
            .step_index = step_u64,
            .logits_position = position_u64,
            .prompt = prompt,
            .generated_prefix = generated_prefix,
            .vocab_size = self.vocab_size,
            .head_binding = self.head_binding,
            .tokenizer_binding = self.provider.tokenizer_binding,
            .policy_binding = self.provider.policy_binding,
            .prefix_sha256 = prefix_sha256,
        };
        if (self.telemetry) |telemetry|
            try self.addUsize(&telemetry.provider_calls, 1);

        var provider_timer: ?std.time.Timer = null;
        if (self.telemetry != null)
            provider_timer = std.time.Timer.start() catch unreachable;
        const provider_result = self.provider.fill(
            self.provider.context,
            &step,
            self.staging_words,
            &certificate,
        );
        const provider_elapsed = if (provider_timer) |*timer| timer.read() else 0;
        if (self.telemetry) |telemetry|
            try self.addNs(&telemetry.provider_ns, provider_elapsed);
        provider_result catch |err| return self.reject(switch (err) {
            EligibilityProviderError.Unavailable => GenerateError.EligibilityProviderUnavailable,
            EligibilityProviderError.InvalidEvidence => GenerateError.EligibilityCertificateRejected,
            EligibilityProviderError.OutOfMemory => GenerateError.OutOfMemory,
        });

        var verification_timer: ?std.time.Timer = null;
        if (self.telemetry != null)
            verification_timer = std.time.Timer.start() catch unreachable;
        @memcpy(self.sealed_words, self.staging_words);
        const eligible_rows = validEligibilityWords(
            self.sealed_words,
            self.vocab_size,
        );
        const mask_sha256 = eligibilityMaskSha256(self.sealed_words);
        const verified = eligible_rows != null and
            certificate.abi == eligibility_provider_abi and
            certificate.generation_epoch == self.provider.generation_epoch and
            certificate.request_nonce == self.request_nonce and
            certificate.step_index == step_u64 and
            certificate.logits_position == position_u64 and
            certificate.not_after_step >= step_u64 and
            std.mem.eql(u8, &certificate.head_binding, &self.head_binding) and
            std.mem.eql(
                u8,
                &certificate.tokenizer_binding,
                &self.provider.tokenizer_binding,
            ) and
            std.mem.eql(
                u8,
                &certificate.policy_binding,
                &self.provider.policy_binding,
            ) and
            std.mem.eql(u8, &certificate.mask_sha256, &mask_sha256) and
            std.mem.eql(
                u8,
                &certificate.prefix_sha256,
                &prefix_sha256,
            ) and
            certificate.eligible_rows == (eligible_rows orelse 0) and
            certificate.tie_rule == .lowest_token_id and
            certificate.operation == .greedy_argmax;
        const verification_elapsed = if (verification_timer) |*timer|
            timer.read()
        else
            0;
        if (self.telemetry) |telemetry|
            try self.addNs(&telemetry.verification_ns, verification_elapsed);
        if (!verified)
            return self.reject(GenerateError.EligibilityCertificateRejected);

        if (self.trace) |*trace| {
            hashEligibilityInt(trace, u8, 1);
            hashEligibilityInt(trace, u64, step_u64);
            hashEligibilityInt(trace, u64, position_u64);
            hashEligibilityInt(trace, u64, certificate.not_after_step);
            hashEligibilityInt(trace, u64, @intCast(eligible_rows.?));
            trace.update(&prefix_sha256);
            trace.update(&mask_sha256);
        }
        if (self.telemetry) |telemetry| {
            try self.addUsize(&telemetry.certificates_accepted, 1);
            try self.addUsize(&telemetry.eligible_rows, eligible_rows.?);
            telemetry.last_mask_sha256 = mask_sha256;
        }
        return eligible_rows.?;
    }

    fn recordPosthead(
        self: *EligibilityState,
        full_logits_bytes: usize,
    ) GenerateError!void {
        if (self.telemetry) |telemetry| {
            try self.addUsize(&telemetry.posthead_projections, 1);
            try self.addUsize(&telemetry.materialized_dot_rows, self.vocab_size);
            try self.addUsize(
                &telemetry.full_logits_rows_written,
                self.vocab_size,
            );
            telemetry.full_logits_peak_bytes = @max(
                telemetry.full_logits_peak_bytes,
                full_logits_bytes,
            );
        }
    }

    fn recordPrehead(
        self: *EligibilityState,
        result: int4_executor.EligibleGreedyResult,
    ) GenerateError!void {
        if (self.telemetry) |telemetry| {
            try self.addUsize(&telemetry.prehead_projections, 1);
            try self.addUsize(&telemetry.producer_rows, result.producer_rows);
            try self.addUsize(&telemetry.skipped_rows, result.skipped_rows);
            try self.addUsize(
                &telemetry.overcomputed_rows,
                result.overcomputed_rows,
            );
            try self.addUsize(&telemetry.producer_runs, result.producer_runs);
            telemetry.executor_tile_scratch_bytes = @max(
                telemetry.executor_tile_scratch_bytes,
                result.tile_scratch_bytes,
            );
        }
    }

    fn recordPublished(
        self: *EligibilityState,
        token: u32,
    ) GenerateError!void {
        const generated_count = std.math.add(
            usize,
            self.generated_prefix_len,
            1,
        ) catch return self.reject(
            GenerateError.EligibilityCertificateRejected,
        );
        var prefix_timer: ?std.time.Timer = null;
        if (self.telemetry != null)
            prefix_timer = std.time.Timer.start() catch unreachable;
        self.prefix_sha256 = extendEligibilityPrefixSha256(
            self.prefix_sha256,
            token,
            generated_count,
        );
        const prefix_elapsed = if (prefix_timer) |*timer| timer.read() else 0;
        self.generated_prefix_len = generated_count;
        if (self.trace) |*trace| {
            hashEligibilityInt(trace, u8, 2);
            hashEligibilityInt(trace, u64, @intCast(generated_count));
            hashEligibilityInt(trace, u32, token);
        }
        if (self.telemetry) |telemetry| {
            try self.addNs(&telemetry.verification_ns, prefix_elapsed);
            try self.addUsize(&telemetry.published_tokens, 1);
        }
    }
};

fn rejectLogitless(options: GenerateOptions) GenerateError {
    if (options.greedy_output_telemetry) |telemetry| telemetry.rejects += 1;
    return GenerateError.LogitlessGreedyUnavailable;
}

fn rejectEligibility(options: GenerateOptions, err: GenerateError) GenerateError {
    if (options.eligibility_telemetry) |telemetry| telemetry.rejects +|= 1;
    return err;
}

fn projectLmHeadGreedy(
    model: loader.LoadedModel,
    hidden: Tensor,
    executor: *int4_executor.Executor,
) GenerateError!u32 {
    const weights = model.lm_head_int4 orelse
        return GenerateError.LogitlessGreedyUnavailable;
    const index = executor.runGreedyArgmax(
        hidden,
        weights,
        model.config.vocab_size,
        model.config.dim,
    ) catch return GenerateError.LogitlessGreedyUnavailable;
    return std.math.cast(u32, index) orelse
        return GenerateError.LogitlessGreedyUnavailable;
}

fn projectLmHeadGreedyEligible(
    model: loader.LoadedModel,
    hidden: Tensor,
    executor: *int4_executor.Executor,
    eligible_words: []const u64,
) GenerateError!int4_executor.EligibleGreedyResult {
    const weights = model.lm_head_int4 orelse
        return GenerateError.EligibilityCertificateRejected;
    return executor.runGreedyArgmaxEligible(
        hidden,
        weights,
        model.config.vocab_size,
        model.config.dim,
        eligible_words,
    ) catch return GenerateError.EligibilityCertificateRejected;
}

fn finishGeneratedSlice(
    allocator: std.mem.Allocator,
    generated: []u32,
    completed_len: usize,
) GenerateError![]u32 {
    std.debug.assert(completed_len <= generated.len);
    if (completed_len == generated.len) return generated;
    return allocator.realloc(generated, completed_len) catch {
        const exact = allocator.alloc(u32, completed_len) catch
            return GenerateError.OutOfMemory;
        @memcpy(exact, generated[0..completed_len]);
        allocator.free(generated);
        return exact;
    };
}

fn admitRequestExecutionTelemetry(
    options: GenerateOptions,
    decode_threads: usize,
) GenerateError!void {
    if (options.request_execution_telemetry == null) return;
    if (decode_threads != 1 or options.num_threads != 1 or
        options.int4_activation != .q8 or
        !options.use_persistent_executor or
        options.mlp_representation != .pair_nibble_required or
        options.decode_frame_mode == .materialized_required or
        options.decode_plan_mode != .checked or
        options.greedy_output_mode != .materialized or
        options.eligible_vocabulary_provider != null or
        options.use_batch_prefill or options.require_batch_prefill or
        pairPrefillFrameRequired(options) or
        options.parallel_attention_min_context != null)
        return GenerateError.ResourceAdmissionUnavailable;
}

fn addExecutionCounter(destination: *usize, amount: usize) GenerateError!void {
    destination.* = std.math.add(usize, destination.*, amount) catch
        return GenerateError.ForwardFailed;
}

fn recordRequestTokenGraph(
    destination: ?*RequestExecutionTelemetry,
    layer_count: usize,
    phase: PairNibblePhase,
) GenerateError!void {
    const out = destination orelse return;
    try addExecutionCounter(&out.token_graphs, 1);
    try addExecutionCounter(&out.active_lane_steps, 1);
    switch (phase) {
        .prefill => try addExecutionCounter(&out.prompt_token_graphs, 1),
        .decode => try addExecutionCounter(&out.decode_token_graphs, 1),
    }
    try addExecutionCounter(&out.layer_graphs, layer_count);
    try addExecutionCounter(
        &out.projection_dispatches,
        std.math.mul(usize, layer_count, 5) catch
            return GenerateError.ForwardFailed,
    );
    try addExecutionCounter(
        &out.qkv_projection_dispatches,
        std.math.mul(usize, layer_count, 3) catch
            return GenerateError.ForwardFailed,
    );
    try addExecutionCounter(&out.pair_dispatches, layer_count);
}

fn recordRequestLmHead(
    destination: ?*RequestExecutionTelemetry,
) GenerateError!void {
    const out = destination orelse return;
    try addExecutionCounter(&out.lm_head_dispatches, 1);
}

fn completeRequestExecutionTelemetry(
    destination: ?*RequestExecutionTelemetry,
    cache_positions: usize,
    prompt_tokens: usize,
    published_tokens: usize,
    layer_count: usize,
) GenerateError!void {
    const out = destination orelse return;
    const expected_decode = published_tokens -| 1;
    const expected_layers = std.math.mul(
        usize,
        cache_positions,
        layer_count,
    ) catch return GenerateError.ForwardFailed;
    const expected_projections = std.math.mul(
        usize,
        expected_layers,
        5,
    ) catch return GenerateError.ForwardFailed;
    const expected_qkv = std.math.mul(
        usize,
        expected_layers,
        3,
    ) catch return GenerateError.ForwardFailed;
    if (out.abi_version != request_execution_telemetry_abi or
        out.admitted_requests != 1 or out.thread_participants != 1 or
        out.prompt_token_graphs != prompt_tokens or
        out.decode_token_graphs != expected_decode or
        out.token_graphs != cache_positions or
        out.active_lane_steps != cache_positions or
        out.layer_graphs != expected_layers or
        out.projection_dispatches != expected_projections or
        out.qkv_projection_dispatches != expected_qkv or
        out.pair_dispatches != expected_layers or
        out.lm_head_dispatches != published_tokens)
        return GenerateError.ForwardFailed;
    out.complete = true;
}

const RequestResourcePlan = struct {
    max_kv_positions: usize,
    mlp_representation: AdmittedMlpRepresentation,
    decode_frame_kind: decode_buffers.MlpFrameKind,
    pair_scratch_spec: int4_executor.PairScratchSpec,
    pair_prefill_frame_policy: PairPrefillFramePolicy,
    domain_output: bool,
    eligibility_head_binding: [32]u8,
    decode_threads: usize,
    strict_pair_prefill: bool,
    batch_prefill_eligible: bool,
    prefill_frame_spec: ?prefill_buffers.Spec,
    require_logitless: bool,
    require_greedy_scratch: bool,
    require_pair_executor: bool,
    packed_executor_required: bool,
    claim: ?resource_bank.Claim,
};

/// Resolve every request property that can change the logical resource claim
/// before consulting the caller allocator. `derive_claim` is false only for
/// ordinary generation without a ResourceBank; public derivation and every
/// committed request both take the exact same true branch.
fn deriveRequestResourcePlan(
    model: loader.LoadedModel,
    prompt: []const u32,
    options: GenerateOptions,
    derive_claim: bool,
) GenerateError!?RequestResourcePlan {
    const cfg = model.config;
    try validateModelLayerCount(cfg.num_layers, model.layers.len);
    if (prompt.len == 0) return GenerateError.ShapeMismatch;
    for (prompt) |token| {
        if (token >= cfg.vocab_size) return GenerateError.ShapeMismatch;
    }
    if (options.resource_commit_observer != null and
        (options.request_resource_bank == null or
            options.max_new_tokens == 0))
        return GenerateError.ResourceCommitObserverRejected;
    if (options.token_publication_observer) |observer|
        if (observer.abi != token_publication_observer_abi)
            return GenerateError.TokenPublicationObserverRejected;

    // The final published token is returned directly and is never fed back
    // through the graph. A non-empty request can therefore commit at most
    // `prompt + max_new - 1` KV rows. Zero-token generation retains its
    // historical prompt-bound validation even though it allocates no cache.
    const max_kv_positions = if (options.max_new_tokens == 0)
        prompt.len
    else
        std.math.add(
            usize,
            prompt.len,
            options.max_new_tokens - 1,
        ) catch return GenerateError.ContextTooLong;
    if (max_kv_positions > forward.max_attention_context)
        return GenerateError.ContextTooLong;
    const mlp_representation = try admitMlpRepresentation(model, options);
    const decode_frame_kind = try selectDecodeFrameKind(
        model,
        mlp_representation,
        options,
    );
    const pair_scratch_spec = try selectPairScratchSpec(
        model,
        mlp_representation,
        options,
    );
    const pair_prefill_frame_policy = try selectPairPrefillFramePolicy(
        mlp_representation,
        options,
    );
    const domain_output = isDomainOutputMode(options.greedy_output_mode);
    if (domain_output != (options.eligible_vocabulary_provider != null))
        return rejectEligibility(
            options,
            GenerateError.EligibilityCertificateRejected,
        );
    const eligibility_head_binding = if (domain_output)
        eligibilityHeadBinding(model)
    else
        [_]u8{0} ** 32;
    if (domain_output) {
        const provider = options.eligible_vocabulary_provider.?;
        if (provider.abi != eligibility_provider_abi or
            isZeroDigest(&model.source_fingerprint) or
            isZeroDigest(&provider.tokenizer_binding) or
            isZeroDigest(&provider.policy_binding) or
            !std.mem.eql(
                u8,
                &provider.head_binding,
                &eligibility_head_binding,
            ) or
            options.sampler.temperature != 0 or
            options.int4_activation != .q8 or
            !options.use_persistent_executor or
            options.forced_tokens.len != 0 or
            options.logits_observer != null or
            !modelSupportsLogitlessGreedy(model, mlp_representation))
            return rejectEligibility(
                options,
                GenerateError.EligibilityCertificateRejected,
            );
    }
    if ((options.require_batch_prefill or pairPrefillFrameRequired(options)) and
        !options.use_batch_prefill)
    {
        if (pairPrefillFrameRequired(options))
            return rejectPairPrefillFrame(options);
        return GenerateError.BatchPrefillUnavailable;
    }
    if (options.decode_plan_mode == .sealed_required and
        (options.int4_activation != .q8 or !options.use_persistent_executor or
            options.parallel_attention_min_context == null or
            options.max_new_tokens < 2 or !modelSupportsSealedDecode(model)))
        return GenerateError.SealedDecodePlanUnavailable;
    if (options.greedy_output_mode == .logitless_required and
        (options.sampler.temperature != 0 or
            options.int4_activation != .q8 or
            !options.use_persistent_executor or
            options.max_new_tokens < 2 or options.forced_tokens.len != 0 or
            options.logits_observer != null or
            !modelSupportsLogitlessGreedy(model, mlp_representation)))
        return rejectLogitless(options);
    if (options.forced_tokens.len != 0 and
        options.forced_tokens.len != options.max_new_tokens)
        return GenerateError.ShapeMismatch;
    for (options.forced_tokens) |token| {
        if (token >= cfg.vocab_size) return GenerateError.ShapeMismatch;
    }
    if (options.max_new_tokens == 0 and
        options.pair_scratch_mode != .automatic)
        return rejectPairScratch(options);
    if (options.max_new_tokens == 0 and pairPrefillFrameRequired(options))
        return rejectPairPrefillFrame(options);
    if (options.max_new_tokens == 0 and
        options.request_execution_telemetry != null)
        return GenerateError.ResourceAdmissionUnavailable;
    if (options.max_new_tokens == 0) return null;

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const requested_threads = if (options.num_threads == 0)
        selectDecodeThreadCount(cpu_count, detectCoreTopology())
    else
        options.num_threads;
    const decode_threads = @min(requested_threads, cpu_count);
    try admitRequestExecutionTelemetry(options, decode_threads);
    if (!pairNibbleParticipantsSupported(mlp_representation, decode_threads))
        return rejectMlpRepresentation(options);

    // Strict batch-frame admission must complete before executor, KV, logits,
    // decode-frame, or rope allocation. Otherwise an ineligible prompt/thread
    // shape could surface an unrelated OOM instead of its fail-closed receipt.
    const strict_pair_prefill = pairPrefillFrameRequired(options);
    var batch_prefill_eligible = options.use_batch_prefill and
        options.int4_activation == .q8 and
        prompt.len >= packed_prefill_min_tokens and decode_threads > 1 and
        modelSupportsPackedBatch(model, mlp_representation);
    if (strict_pair_prefill and !batch_prefill_eligible)
        return rejectPairPrefillFrame(options);
    if (options.require_batch_prefill and !batch_prefill_eligible)
        return GenerateError.BatchPrefillUnavailable;
    if (!batch_prefill_eligible and
        pair_prefill_frame_policy != .disabled)
    {
        if (options.pair_prefill_frame_telemetry) |telemetry|
            telemetry.fallbacks +|= 1;
    }
    var prefill_frame_spec: ?prefill_buffers.Spec = null;
    if (batch_prefill_eligible) {
        const chunk_capacity = @min(prompt.len, packed_prefill_chunk_rows);
        const derived: ?prefill_buffers.Spec = pairPrefillBufferSpec(
            model,
            pair_prefill_frame_policy,
            chunk_capacity,
            decode_threads,
        ) catch blk: {
            if (strict_pair_prefill)
                return rejectPairPrefillFrame(options);
            if (options.require_batch_prefill)
                return GenerateError.BatchPrefillUnavailable;
            if (pair_prefill_frame_policy != .disabled) {
                if (options.pair_prefill_frame_telemetry) |telemetry|
                    telemetry.fallbacks +|= 1;
            }
            batch_prefill_eligible = false;
            break :blk null;
        };
        prefill_frame_spec = derived;
    }
    if (options.decode_plan_mode == .sealed_required) {
        const threshold = options.parallel_attention_min_context orelse
            return GenerateError.SealedDecodePlanUnavailable;
        const first_decode_context = std.math.add(usize, prompt.len, 1) catch
            return GenerateError.ContextTooLong;
        if (first_decode_context < threshold or cfg.num_heads <= 1 or
            decode_threads <= 1)
            return GenerateError.SealedDecodePlanUnavailable;
    }

    var packed_graph = options.use_persistent_executor and
        model.lm_head_int4 != null;
    for (model.layers) |layer| {
        packed_graph = packed_graph and layer.wq_int4 != null and
            layer.wk_int4 != null and layer.wv_int4 != null and
            layer.wo_int4 != null and layer.w_down_int4 != null;
        packed_graph = packed_graph and switch (mlp_representation) {
            .separate => layer.w_gate_int4 != null and
                layer.w_up_int4 != null,
            .pair_nibble => layer.w_gate_up_pair_int4 != null and
                layer.w_gate_int4 == null and layer.w_up_int4 == null,
        };
    }

    const require_logitless = options.greedy_output_mode ==
        .logitless_required;
    const require_prehead = options.greedy_output_mode ==
        .domain_prehead_required;
    const require_domain_executor = domain_output;
    const require_greedy_scratch = require_logitless or require_prehead;
    const require_pair_executor = mlp_representation == .pair_nibble;
    const packed_executor_required = packed_graph and
        (decode_threads > 1 or require_logitless or require_domain_executor or
            require_pair_executor);
    const claim = if (derive_claim)
        deriveRequestResourceClaim(
            model,
            options,
            max_kv_positions,
            decode_threads,
            decode_frame_kind,
            pair_scratch_spec,
            prefill_frame_spec,
            batch_prefill_eligible,
            packed_graph,
            packed_executor_required,
            require_greedy_scratch,
        ) catch |err| {
            if (options.request_resource_telemetry) |telemetry|
                telemetry.derive_rejects +|= 1;
            return err;
        }
    else
        null;
    return .{
        .max_kv_positions = max_kv_positions,
        .mlp_representation = mlp_representation,
        .decode_frame_kind = decode_frame_kind,
        .pair_scratch_spec = pair_scratch_spec,
        .pair_prefill_frame_policy = pair_prefill_frame_policy,
        .domain_output = domain_output,
        .eligibility_head_binding = eligibility_head_binding,
        .decode_threads = decode_threads,
        .strict_pair_prefill = strict_pair_prefill,
        .batch_prefill_eligible = batch_prefill_eligible,
        .prefill_frame_spec = prefill_frame_spec,
        .require_logitless = require_logitless,
        .require_greedy_scratch = require_greedy_scratch,
        .require_pair_executor = require_pair_executor,
        .packed_executor_required = packed_executor_required,
        .claim = claim,
    };
}

/// Derive the exact ResourceBank claim that `generate` will commit for this
/// model, prompt, and option set. The function is allocation-free, performs
/// the same strict admission checks as execution, invokes no callbacks, and
/// makes no Bank transition. A zero-token request has no execution receipt and
/// is therefore rejected as unavailable.
pub fn deriveResourceClaim(
    model: loader.LoadedModel,
    prompt: []const u32,
    options: GenerateOptions,
) GenerateError!resource_bank.Claim {
    const plan = (try deriveRequestResourcePlan(
        model,
        prompt,
        options,
        true,
    )) orelse return GenerateError.ResourceAdmissionUnavailable;
    return plan.claim orelse return GenerateError.ResourceAdmissionUnavailable;
}

/// Generate `max_new_tokens` tokens autoregressively from a prompt using
/// a KV cache. Returns the generated token ids (caller owns).
pub fn generate(
    allocator: std.mem.Allocator,
    model: loader.LoadedModel,
    prompt: []const u32,
    options: GenerateOptions,
) GenerateError![]u32 {
    const cfg = model.config;
    if (options.phase_telemetry) |telemetry| telemetry.* = .{};
    if (options.decode_plan_telemetry) |telemetry| telemetry.* = .{};
    if (options.greedy_output_telemetry) |telemetry| telemetry.* = .{};
    if (options.eligibility_telemetry) |telemetry| telemetry.* = .{};
    if (options.pair_nibble_telemetry) |telemetry| telemetry.* = .{};
    if (options.pair_scratch_telemetry) |telemetry| telemetry.* = .{};
    if (options.pair_prefill_frame_telemetry) |telemetry| telemetry.* = .{};
    if (options.request_resource_telemetry) |telemetry| telemetry.* = .{};
    if (options.generation_state_telemetry) |telemetry| telemetry.* = .{};
    if (options.request_execution_telemetry) |telemetry| telemetry.* = .{};
    if (options.prefill_path_out) |path| path.* = .serial;
    const maybe_resource_plan = try deriveRequestResourcePlan(
        model,
        prompt,
        options,
        options.request_resource_bank != null,
    );
    if (maybe_resource_plan == null) {
        const kv_dim = std.math.mul(
            usize,
            cfg.num_kv_heads,
            cfg.head_dim,
        ) catch return GenerateError.ShapeMismatch;
        const result = allocator.alloc(u32, 0) catch
            return GenerateError.OutOfMemory;
        if (options.generation_state_telemetry) |telemetry| {
            const initial_prng = std.Random.DefaultPrng.init(options.seed);
            telemetry.* = .{
                .complete = true,
                .kv_sha256 = emptyLogicalKvSha256(cfg.num_layers, kv_dim),
                .output_sha256 = tokenSequenceSha256(&.{}),
                .rng_state = initial_prng.s,
            };
        }
        return result;
    }
    const resource_plan = maybe_resource_plan.?;
    const max_kv_positions = resource_plan.max_kv_positions;
    const mlp_representation = resource_plan.mlp_representation;
    const decode_frame_kind = resource_plan.decode_frame_kind;
    const pair_scratch_spec = resource_plan.pair_scratch_spec;
    const pair_prefill_frame_policy = resource_plan.pair_prefill_frame_policy;
    const domain_output = resource_plan.domain_output;
    const eligibility_head_binding = resource_plan.eligibility_head_binding;
    const decode_threads = resource_plan.decode_threads;
    const strict_pair_prefill = resource_plan.strict_pair_prefill;
    const batch_prefill_eligible = resource_plan.batch_prefill_eligible;
    const prefill_frame_spec = resource_plan.prefill_frame_spec;
    const require_logitless = resource_plan.require_logitless;
    const require_greedy_scratch = resource_plan.require_greedy_scratch;
    const require_pair_executor = resource_plan.require_pair_executor;
    const packed_executor_required = resource_plan.packed_executor_required;

    // Strict Pair execution needs the persistent consumer even at M1 with one
    // participant. Construct it before KV/request buffers so an unavailable
    // executor cannot leave a large request allocation preceding rejection.
    var packed_executor: int4_executor.Executor = undefined;
    var packed_executor_ptr: ?*int4_executor.Executor = null;

    // Reserve and commit the complete logical request bound before the first
    // executor/KV/frame/logit/output allocation. The receipt remains charged
    // for the whole synchronous execution and is released after ownership of
    // the returned output journal transfers to the caller.
    var request_resource_claim: ?resource_bank.Claim = null;
    var request_resource_owner_key: u64 = 0;
    var request_resource_receipt: ?resource_bank.Receipt = null;
    defer if (options.request_resource_bank) |bank| {
        if (request_resource_receipt) |receipt| {
            bank.release(receipt) catch {
                if (options.request_resource_telemetry) |telemetry|
                    telemetry.release_failures +|= 1;
            };
        }
        recordRequestResourceTelemetry(
            options.request_resource_telemetry,
            bank,
            request_resource_claim,
            request_resource_owner_key,
            request_resource_receipt,
        );
    };
    if (options.request_resource_bank) |bank| {
        const claim = resource_plan.claim orelse
            return GenerateError.ResourceAdmissionUnavailable;
        const owner_key = requestResourceOwnerKey(
            model,
            prompt,
            options,
            decode_threads,
            decode_frame_kind,
            pair_scratch_spec,
            pair_prefill_frame_policy,
        );
        request_resource_claim = claim;
        request_resource_owner_key = owner_key;
        const reservation = bank.reserve(owner_key, claim) catch |err| {
            recordRequestResourceTelemetry(
                options.request_resource_telemetry,
                bank,
                claim,
                owner_key,
                null,
            );
            return mapResourceBankError(err);
        };
        const receipt = bank.commit(reservation) catch |err| {
            bank.cancel(reservation) catch {
                if (options.request_resource_telemetry) |telemetry|
                    telemetry.release_failures +|= 1;
            };
            recordRequestResourceTelemetry(
                options.request_resource_telemetry,
                bank,
                claim,
                owner_key,
                null,
            );
            return mapResourceBankError(err);
        };
        request_resource_receipt = receipt;
        recordRequestResourceTelemetry(
            options.request_resource_telemetry,
            bank,
            claim,
            owner_key,
            receipt,
        );
        // `commit` and the telemetry snapshot have both dropped the Bank
        // mutex here. A failing observer returns through the existing receipt
        // defer, which remains the sole release site for this execution.
        if (options.resource_commit_observer) |observer|
            try runResourceCommitObserver(observer, receipt);
    }
    if (packed_executor_required) {
        const initialized = blk: {
            packed_executor.initWithOptions(
                allocator,
                decode_threads,
                .{
                    .greedy_argmax = require_greedy_scratch,
                    .pair_scratch = pair_scratch_spec,
                },
            ) catch |err| {
                if (err == error.OutOfMemory)
                    return GenerateError.OutOfMemory;
                break :blk false;
            };
            break :blk true;
        };
        if (initialized) {
            packed_executor_ptr = &packed_executor;
            recordPairScratchTelemetry(
                options.pair_scratch_telemetry,
                packed_executor.pairScratchTelemetry(),
            );
        }
    }
    defer if (packed_executor_ptr) |executor| {
        recordPairScratchTelemetry(
            options.pair_scratch_telemetry,
            executor.pairScratchTelemetry(),
        );
        executor.deinit();
    };

    if (require_pair_executor and packed_executor_ptr == null)
        return rejectMlpRepresentation(options);
    if (require_logitless and packed_executor_ptr == null)
        return rejectLogitless(options);
    if (domain_output and packed_executor_ptr == null)
        return rejectEligibility(
            options,
            GenerateError.EligibilityCertificateRejected,
        );
    if (require_greedy_scratch) {
        if (options.greedy_output_telemetry) |telemetry| {
            telemetry.scratch_bytes =
                packed_executor_ptr.?.greedyArgmaxScratchBytes();
        }
        if (options.eligibility_telemetry) |telemetry| {
            telemetry.executor_candidate_bytes =
                packed_executor_ptr.?.greedyArgmaxScratchBytes();
        }
    }
    if (options.decode_plan_mode == .sealed_required and
        packed_executor_ptr == null)
        return GenerateError.SealedDecodePlanUnavailable;
    if (options.request_execution_telemetry) |telemetry| {
        telemetry.admitted_requests = 1;
        telemetry.thread_participants = decode_threads;
    }

    // KV cache stores K/V rows of width num_kv_heads*head_dim (kv_dim),
    // NOT the full dim — GQA models have smaller K/V than Q.
    const kv_dim = cfg.num_kv_heads * cfg.head_dim;
    var cache = kv.KVCache.init(
        allocator,
        cfg.num_layers,
        kv_dim,
        max_kv_positions,
    ) catch
        return GenerateError.OutOfMemory;
    defer cache.deinit();

    var generated = allocator.alloc(u32, options.max_new_tokens) catch
        return GenerateError.OutOfMemory;
    errdefer allocator.free(generated);

    var eligibility_state: ?EligibilityState = null;
    if (options.eligible_vocabulary_provider) |provider| {
        eligibility_state = try EligibilityState.init(
            allocator,
            provider,
            eligibility_head_binding,
            cfg.vocab_size,
            prompt,
            options.eligibility_telemetry,
        );
    }
    defer if (eligibility_state) |*state| state.deinit();

    // Arena allocator for decode-loop temporaries. Arena alloc is O(1)
    // (pointer bump) vs GPA's O(log n) per alloc. We reset the arena
    // between decode steps so memory doesn't grow unboundedly.
    // The prefill loop also uses the arena (same rationale).

    // layer_cfg for the cached decode path.
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

    // --- Prefill: process each prompt token through forwardLayerCached.
    // This populates the KV cache AND gives us logits from the last token.
    // Prompt positions stay sequential; large packed projections can use the
    // persistent pool created below.
    // Shape storage for Tensor views used in prefill/decode loops.
    var s_next: [2]usize = undefined;
    var s_final: [2]usize = undefined;

    var last_logits_storage: Tensor = undefined;
    var last_logits: ?*Tensor = null;
    if (options.greedy_output_mode != .domain_prehead_required) {
        last_logits_storage = tensor.zerosF32(
            allocator,
            &.{ 1, cfg.vocab_size },
        ) catch return GenerateError.OutOfMemory;
        last_logits = &last_logits_storage;
    }
    defer if (last_logits) |logits| logits.deinit();

    var x_row = tensor.zerosF32(allocator, &.{ 1, cfg.dim }) catch
        return GenerateError.OutOfMemory;
    defer x_row.deinit();
    // Batch prefill may normalize directly into x_row. Serial prefill instead
    // points this view at the existing final-layer request buffer, preserving
    // the old allocation geometry for non-domain generation.
    var prefill_final_hidden = x_row;

    // Pre-allocate one depth-independent activation frame. Layer execution is
    // synchronously joined, so reusing it keeps decode allocation-free without
    // multiplying request scratch by model depth.
    var buffers = decode_buffers.DecodeBuffers.initWithFrame(
        allocator,
        cfg.num_layers,
        cfg.dim,
        kv_dim,
        cfg.hidden_dim,
        decode_frame_kind,
    ) catch
        return GenerateError.OutOfMemory;
    defer buffers.deinit();
    if (options.pair_nibble_telemetry) |telemetry| {
        switch (decode_frame_kind) {
            .materialized => telemetry.decode_frame_materialized_uses = 1,
            .compact_pair_g8, .compact_pair_g16 => telemetry.decode_frame_compact_pair_uses = 1,
        }
        telemetry.decode_frame_tensor_bytes = buffers.tensorStorageBytes();
        telemetry.decode_frame_materialized_bytes =
            buffers.materializedCounterfactualBytes();
        telemetry.decode_frame_reclaimed_bytes = buffers.reclaimedPayloadBytes();
        telemetry.pair_q8_scratch_bytes = buffers.shared.pair_q8.len;
        telemetry.pair_activation_scale_bytes =
            buffers.shared.pair_scales.len * @sizeOf(f32);
    }

    var rope_table = RopeTable.init(
        allocator,
        max_kv_positions,
        cfg.head_dim,
        cfg.rope_theta,
    ) catch
        return GenerateError.OutOfMemory;
    defer rope_table.deinit();

    var decode_plans: []?SealedDecodeLayerPlan = @constCast(
        &[_]?SealedDecodeLayerPlan{},
    );
    if (options.decode_plan_mode == .sealed_required) {
        decode_plans = allocator.alloc(
            ?SealedDecodeLayerPlan,
            cfg.num_layers,
        ) catch return GenerateError.OutOfMemory;
        @memset(decode_plans, null);
        if (options.decode_plan_telemetry) |telemetry| {
            telemetry.plan_sets = 1;
            telemetry.plan_set_bytes = std.math.mul(
                usize,
                decode_plan_slot_bytes,
                cfg.num_layers,
            ) catch return GenerateError.OutOfMemory;
        }
    }
    defer if (decode_plans.len != 0) allocator.free(decode_plans);

    // The legacy pool handles unpacked/mixed models, explicit A/B runs, and
    // persistent-executor initialization failures.
    var decode_pool: std.Thread.Pool = undefined;
    var decode_pool_ptr: ?*std.Thread.Pool = null;
    if (decode_threads > 1 and packed_executor_ptr == null) {
        const worker_count = decode_threads - 1;
        const initialized = blk: {
            // Pool closures are short-lived and numerous; libc malloc is
            // materially cheaper than the debug/general allocator's page
            // bookkeeping on this hot scheduling path.
            decode_pool.init(.{ .allocator = std.heap.c_allocator, .n_jobs = worker_count }) catch break :blk false;
            break :blk true;
        };
        if (initialized) decode_pool_ptr = &decode_pool;
    }
    defer if (decode_pool_ptr != null) decode_pool.deinit();

    var projection_worker: ProjectionWorker = undefined;
    var projection_worker_ptr: ?*ProjectionWorker = null;
    if (decode_pool_ptr != null) {
        const initialized = blk: {
            projection_worker.init() catch break :blk false;
            break :blk true;
        };
        if (initialized) projection_worker_ptr = &projection_worker;
    }
    defer if (projection_worker_ptr) |worker| worker.deinit();

    var batch_prefill_complete = false;
    var prepared_eligible_rows: usize = 0;
    if (eligibility_state) |*state| {
        prepared_eligible_rows = try state.prepare(
            0,
            prompt.len - 1,
            prompt,
            generated[0..0],
        );
    }
    if (batch_prefill_eligible) {
        batch_prefill_complete = blk: {
            runPackedBatchPrefill(
                allocator,
                model,
                prompt,
                layer_cfg,
                &cache,
                x_row,
                &rope_table,
                decode_threads,
                options.request_ready_telemetry,
                options.phase_telemetry,
                mlp_representation,
                options.pair_nibble_telemetry,
                pair_prefill_frame_policy,
                options.pair_prefill_frame_telemetry,
                prefill_frame_spec.?,
            ) catch |err| {
                // The fast path is optional. Logical reset is sufficient:
                // token-at-a-time fallback overwrites every populated row.
                cache.reset();
                if (strict_pair_prefill) {
                    if (options.pair_prefill_frame_telemetry) |telemetry|
                        telemetry.rejects +|= 1;
                    return err;
                }
                if (options.require_batch_prefill) return err;
                if (pair_prefill_frame_policy != .disabled) {
                    if (options.pair_prefill_frame_telemetry) |telemetry|
                        telemetry.fallbacks +|= 1;
                }
                break :blk false;
            };
            break :blk true;
        };
    }
    if (batch_prefill_complete) {
        if (options.prefill_path_out) |path| path.* = .batch;
    }

    if (!batch_prefill_complete) {
        if (options.request_ready_telemetry) |telemetry| {
            telemetry.elapsed_ns_out.* = telemetry.process_timer.read();
        }
        var prefill_timer: ?std.time.Timer = null;
        if (options.phase_telemetry != null) {
            prefill_timer = std.time.Timer.start() catch unreachable;
        }
        for (prompt, 0..) |prompt_token, prompt_pos| {
            try loadEmbeddingRow(model, prompt_token, x_row.asF32Unsafe());

            for (model.layers, 0..) |lw, i| {
                const layer_buffers = buffers.forLayer(i);
                const next_h_view = decode_buffers.DecodeBuffers.view(layer_buffers.next_h, &s_next, cfg.dim);
                // Keep token-at-a-time fallback prefill serial so the decode
                // crossover knob cannot contaminate prompt-phase A/B timing.
                try forwardLayerCached(
                    layer_cfg,
                    lw,
                    x_row,
                    &cache,
                    i,
                    prompt_pos,
                    layer_buffers,
                    next_h_view,
                    decode_pool_ptr,
                    projection_worker_ptr,
                    packed_executor_ptr,
                    null,
                    null,
                    null,
                    null,
                    null,
                    .checked,
                    null,
                    null,
                    mlp_representation,
                    options.pair_nibble_telemetry,
                    .prefill,
                    options.int4_activation,
                    &rope_table,
                );
                @memcpy(x_row.asF32Unsafe(), layer_buffers.next_h);
            }
            cache.commit();
            try recordRequestTokenGraph(
                options.request_execution_telemetry,
                cfg.num_layers,
                .prefill,
            );

            if (prompt_pos == prompt.len - 1) {
                const last_layer = cfg.num_layers - 1;
                const final_h = decode_buffers.DecodeBuffers.view(
                    buffers.forLayer(last_layer).next_h,
                    &s_final,
                    cfg.dim,
                );
                kernels.rmsNormF32(
                    x_row,
                    model.final_norm,
                    cfg.rms_eps,
                    final_h,
                ) catch
                    return GenerateError.ForwardFailed;
                prefill_final_hidden = final_h;
            }
        }
        if (options.phase_telemetry) |telemetry| {
            const elapsed = prefill_timer.?.read();
            telemetry.prefill_graph_ns = elapsed;
            telemetry.prefill_ns = elapsed;
        }
    }

    var first_head_timer: ?std.time.Timer = null;
    if (options.phase_telemetry != null)
        first_head_timer = std.time.Timer.start() catch unreachable;
    var first_direct_greedy_token: ?u32 = null;
    switch (options.greedy_output_mode) {
        .materialized, .logitless_required, .domain_posthead_required => {
            const logits = last_logits orelse
                return GenerateError.ForwardFailed;
            try projectLmHead(
                model,
                prefill_final_hidden,
                logits.*,
                decode_pool_ptr,
                packed_executor_ptr,
                options.int4_activation,
            );
            if (options.greedy_output_telemetry) |telemetry| {
                telemetry.materialized_projections += 1;
                telemetry.materialized_logits_bytes = logits.data.len;
            }
        },
        .domain_prehead_required => {
            const state = if (eligibility_state) |*value| value else return rejectEligibility(
                options,
                GenerateError.EligibilityCertificateRejected,
            );
            const executor = packed_executor_ptr orelse
                return state.reject(
                    GenerateError.EligibilityCertificateRejected,
                );
            const result = projectLmHeadGreedyEligible(
                model,
                prefill_final_hidden,
                executor,
                state.sealed_words,
            ) catch return state.reject(
                GenerateError.EligibilityCertificateRejected,
            );
            if (result.eligible_rows != prepared_eligible_rows)
                return state.reject(
                    GenerateError.EligibilityCertificateRejected,
                );
            try state.recordPrehead(result);
            if (options.greedy_output_telemetry) |telemetry| {
                telemetry.logitless_projections += 1;
                telemetry.producer_rows = std.math.add(
                    usize,
                    telemetry.producer_rows,
                    result.producer_rows,
                ) catch return state.reject(
                    GenerateError.EligibilityCertificateRejected,
                );
            }
            first_direct_greedy_token = std.math.cast(
                u32,
                result.token_index,
            ) orelse return state.reject(
                GenerateError.EligibilityCertificateRejected,
            );
        },
    }
    try recordRequestLmHead(options.request_execution_telemetry);
    if (options.phase_telemetry) |telemetry| {
        const elapsed = first_head_timer.?.read();
        telemetry.first_head_ns = elapsed;
        // Preserve the historical aggregate while exposing the graph/head
        // boundary needed for strict prefill evidence.
        telemetry.prefill_ns += elapsed;
    }

    // --- Decode: sample, then feed back via forwardLayerCached. ---------
    // O(n) per token — only the new token is processed, not the full seq.
    var rng_prng = std.Random.DefaultPrng.init(options.seed);
    const rng = rng_prng.random();
    const sample_scratch_len = if (options.forced_tokens.len == 0 and
        options.sampler.temperature != 0)
        cfg.vocab_size
    else
        0;
    const sample_scratch = allocator.alloc(sampling.Candidate, sample_scratch_len) catch
        return GenerateError.OutOfMemory;
    defer allocator.free(sample_scratch);

    var gen_count: usize = 0;
    var sampling_calls: usize = 0;
    var next_token: u32 = if (options.forced_tokens.len != 0) blk: {
        const target = options.forced_tokens[0];
        if (options.logits_observer) |observer|
            observer.observe(
                observer.context,
                last_logits.?.asF32Unsafe(),
                target,
            );
        break :blk target;
    } else if (first_direct_greedy_token) |token| token else blk: {
        const logits = last_logits orelse
            return GenerateError.ForwardFailed;
        var sampling_timer: ?std.time.Timer = null;
        if (options.phase_telemetry != null)
            sampling_timer = std.time.Timer.start() catch unreachable;
        if (options.greedy_output_mode == .domain_posthead_required) {
            const state = if (eligibility_state) |*value| value else return rejectEligibility(
                options,
                GenerateError.EligibilityCertificateRejected,
            );
            const result = sampling.argmaxEligible(
                logits.asF32Unsafe(),
                state.sealed_words,
            ) catch return state.reject(
                GenerateError.EligibilityCertificateRejected,
            );
            if (result.eligible_rows != prepared_eligible_rows)
                return state.reject(
                    GenerateError.EligibilityCertificateRejected,
                );
            try state.recordPosthead(logits.data.len);
            if (options.phase_telemetry) |telemetry|
                telemetry.sampling_ns += sampling_timer.?.read();
            break :blk std.math.cast(u32, result.token_index) orelse
                return state.reject(
                    GenerateError.EligibilityCertificateRejected,
                );
        }
        sampling_calls += 1;
        const token: u32 = @intCast(sampling.sample(
            logits.asF32Unsafe(),
            options.sampler,
            rng,
            sample_scratch,
        ));
        if (options.phase_telemetry) |telemetry| {
            telemetry.sampling_ns += sampling_timer.?.read();
        }
        break :blk token;
    };
    if (require_logitless) {
        const logits = last_logits orelse return rejectLogitless(options);
        const reclaimed_bytes = logits.data.len;
        logits.deinit();
        last_logits = null;
        if (options.greedy_output_telemetry) |telemetry|
            telemetry.steady_state_reclaimed_bytes = reclaimed_bytes;
    }

    while (gen_count < options.max_new_tokens) : (gen_count += 1) {
        generated[gen_count] = next_token;
        if (eligibility_state) |*state| try state.recordPublished(next_token);
        const terminal = next_token == options.eos_token or
            gen_count + 1 == options.max_new_tokens;
        if (options.token_publication_observer) |observer|
            try runTokenPublicationObserver(
                observer,
                gen_count,
                next_token,
                terminal,
            );
        if (options.on_token) |cb| cb(next_token);
        if (next_token == options.eos_token) {
            const completed = try finishGeneratedSlice(
                allocator,
                generated,
                gen_count + 1,
            );
            try completeRequestExecutionTelemetry(
                options.request_execution_telemetry,
                cache.len,
                prompt.len,
                completed.len,
                cfg.num_layers,
            );
            recordCompletedGenerationState(
                options.generation_state_telemetry,
                &cache,
                completed,
                sampling_calls,
                &rng_prng,
            );
            return completed;
        }
        // The final sampled token is already an output. Do not run a full
        // forward pass whose logits will never be consumed.
        if (gen_count + 1 == options.max_new_tokens) {
            const completed = generated[0 .. gen_count + 1];
            try completeRequestExecutionTelemetry(
                options.request_execution_telemetry,
                cache.len,
                prompt.len,
                completed.len,
                cfg.num_layers,
            );
            recordCompletedGenerationState(
                options.generation_state_telemetry,
                &cache,
                completed,
                sampling_calls,
                &rng_prng,
            );
            return completed;
        }

        if (eligibility_state) |*state| {
            prepared_eligible_rows = try state.prepare(
                gen_count + 1,
                prompt.len + gen_count,
                prompt,
                generated[0 .. gen_count + 1],
            );
        }

        // Reset arena — all per-token temporaries are bump-allocated.

        var decode_timer: ?std.time.Timer = null;
        if (options.phase_telemetry != null) {
            decode_timer = std.time.Timer.start() catch unreachable;
        }

        // Embedding for the just-sampled token.
        try loadEmbeddingRow(model, next_token, x_row.asF32Unsafe());

        const cur_pos = prompt.len + gen_count;
        const parallel_attention_dispatches_out = if (options.phase_telemetry) |telemetry|
            &telemetry.parallel_attention_dispatches
        else
            null;
        const handoff_dispatches_out = if (options.phase_telemetry) |telemetry|
            &telemetry.handoff_dispatches
        else
            null;
        const fused_gqa_dispatches_out = if (options.phase_telemetry) |telemetry|
            &telemetry.fused_gqa_dispatches
        else
            null;
        const paired_mlp_dispatches_out = if (options.phase_telemetry) |telemetry|
            &telemetry.paired_mlp_dispatches
        else
            null;
        const attention_dispatches_before = if (options.phase_telemetry) |telemetry|
            telemetry.parallel_attention_dispatches
        else
            0;
        const handoff_dispatches_before = if (options.phase_telemetry) |telemetry|
            telemetry.handoff_dispatches
        else
            0;
        const fused_gqa_dispatches_before = if (options.phase_telemetry) |telemetry|
            telemetry.fused_gqa_dispatches
        else
            0;
        const paired_mlp_dispatches_before = if (options.phase_telemetry) |telemetry|
            telemetry.paired_mlp_dispatches
        else
            0;

        // Run all layers through the cached path — O(n) per token, zero alloc.
        for (model.layers, 0..) |lw, i| {
            const layer_buffers = buffers.forLayer(i);
            const next_h_view = decode_buffers.DecodeBuffers.view(layer_buffers.next_h, &s_next, cfg.dim);
            const decode_plan_slot = if (options.decode_plan_mode == .sealed_required)
                &decode_plans[i]
            else
                null;
            try forwardLayerCached(
                layer_cfg,
                lw,
                x_row,
                &cache,
                i,
                cur_pos,
                layer_buffers,
                next_h_view,
                decode_pool_ptr,
                projection_worker_ptr,
                packed_executor_ptr,
                options.parallel_attention_min_context,
                parallel_attention_dispatches_out,
                handoff_dispatches_out,
                fused_gqa_dispatches_out,
                paired_mlp_dispatches_out,
                options.decode_plan_mode,
                decode_plan_slot,
                options.decode_plan_telemetry,
                mlp_representation,
                options.pair_nibble_telemetry,
                .decode,
                options.int4_activation,
                &rope_table,
            );
            @memcpy(x_row.asF32Unsafe(), layer_buffers.next_h);
        }
        if (options.phase_telemetry) |telemetry| {
            try finishParallelAttentionGraph(
                telemetry,
                attention_dispatches_before,
                handoff_dispatches_before,
                fused_gqa_dispatches_before,
                paired_mlp_dispatches_before,
                cfg.num_layers,
            );
        }
        cache.commit();

        // Logits: rmsNorm on x_row (which holds the last layer's output)
        // then lm_head projection. Use the last layer's next_h buffer
        // (not mlp_norm — that was overwritten during the forward pass).
        const last_layer = cfg.num_layers - 1;
        const final_h = decode_buffers.DecodeBuffers.view(buffers.forLayer(last_layer).next_h, &s_final, cfg.dim);
        kernels.rmsNormF32(x_row, model.final_norm, cfg.rms_eps, final_h) catch
            return GenerateError.ForwardFailed;
        const direct_greedy_token: ?u32 = switch (options.greedy_output_mode) {
            .materialized, .domain_posthead_required => blk: {
                const logits = last_logits orelse
                    return GenerateError.ForwardFailed;
                try projectLmHead(
                    model,
                    final_h,
                    logits.*,
                    decode_pool_ptr,
                    packed_executor_ptr,
                    options.int4_activation,
                );
                if (options.greedy_output_telemetry) |telemetry|
                    telemetry.materialized_projections += 1;
                break :blk null;
            },
            .logitless_required => blk: {
                const executor = packed_executor_ptr orelse
                    return rejectLogitless(options);
                const token = projectLmHeadGreedy(
                    model,
                    final_h,
                    executor,
                ) catch return rejectLogitless(options);
                if (options.greedy_output_telemetry) |telemetry| {
                    telemetry.logitless_projections = std.math.add(
                        usize,
                        telemetry.logitless_projections,
                        1,
                    ) catch return rejectLogitless(options);
                    telemetry.producer_rows = std.math.add(
                        usize,
                        telemetry.producer_rows,
                        cfg.vocab_size,
                    ) catch return rejectLogitless(options);
                }
                break :blk token;
            },
            .domain_prehead_required => blk: {
                const state = if (eligibility_state) |*value| value else return rejectEligibility(
                    options,
                    GenerateError.EligibilityCertificateRejected,
                );
                const executor = packed_executor_ptr orelse
                    return state.reject(
                        GenerateError.EligibilityCertificateRejected,
                    );
                const result = projectLmHeadGreedyEligible(
                    model,
                    final_h,
                    executor,
                    state.sealed_words,
                ) catch return state.reject(
                    GenerateError.EligibilityCertificateRejected,
                );
                if (result.eligible_rows != prepared_eligible_rows)
                    return state.reject(
                        GenerateError.EligibilityCertificateRejected,
                    );
                try state.recordPrehead(result);
                if (options.greedy_output_telemetry) |telemetry| {
                    telemetry.logitless_projections = std.math.add(
                        usize,
                        telemetry.logitless_projections,
                        1,
                    ) catch return state.reject(
                        GenerateError.EligibilityCertificateRejected,
                    );
                    telemetry.producer_rows = std.math.add(
                        usize,
                        telemetry.producer_rows,
                        result.producer_rows,
                    ) catch return state.reject(
                        GenerateError.EligibilityCertificateRejected,
                    );
                }
                break :blk std.math.cast(u32, result.token_index) orelse
                    return state.reject(
                        GenerateError.EligibilityCertificateRejected,
                    );
            },
        };
        try recordRequestTokenGraph(
            options.request_execution_telemetry,
            cfg.num_layers,
            .decode,
        );
        try recordRequestLmHead(options.request_execution_telemetry);
        if (options.phase_telemetry) |telemetry| {
            telemetry.decode_graph_ns += decode_timer.?.read();
            telemetry.decode_graph_runs += 1;
        }

        if (options.forced_tokens.len != 0) {
            const target = options.forced_tokens[gen_count + 1];
            if (options.logits_observer) |observer|
                observer.observe(
                    observer.context,
                    last_logits.?.asF32Unsafe(),
                    target,
                );
            next_token = target;
        } else if (direct_greedy_token) |token| {
            next_token = token;
        } else {
            const logits = last_logits orelse
                return GenerateError.ForwardFailed;
            var sampling_timer: ?std.time.Timer = null;
            if (options.phase_telemetry != null)
                sampling_timer = std.time.Timer.start() catch unreachable;
            if (options.greedy_output_mode == .domain_posthead_required) {
                const state = if (eligibility_state) |*value| value else return rejectEligibility(
                    options,
                    GenerateError.EligibilityCertificateRejected,
                );
                const result = sampling.argmaxEligible(
                    logits.asF32Unsafe(),
                    state.sealed_words,
                ) catch return state.reject(
                    GenerateError.EligibilityCertificateRejected,
                );
                if (result.eligible_rows != prepared_eligible_rows)
                    return state.reject(
                        GenerateError.EligibilityCertificateRejected,
                    );
                try state.recordPosthead(logits.data.len);
                next_token = std.math.cast(u32, result.token_index) orelse
                    return state.reject(
                        GenerateError.EligibilityCertificateRejected,
                    );
                if (options.phase_telemetry) |telemetry|
                    telemetry.sampling_ns += sampling_timer.?.read();
                continue;
            }
            sampling_calls += 1;
            next_token = @intCast(sampling.sample(
                logits.asF32Unsafe(),
                options.sampler,
                rng,
                sample_scratch,
            ));
            if (options.phase_telemetry) |telemetry| {
                telemetry.sampling_ns += sampling_timer.?.read();
            }
        }
    }

    recordCompletedGenerationState(
        options.generation_state_telemetry,
        &cache,
        generated,
        sampling_calls,
        &rng_prng,
    );
    return generated;
}

test "precomputed RoPE matches the direct decode formula" {
    const allocator = std.testing.allocator;
    var table = try RopeTable.init(allocator, 8, 8, 10000.0);
    defer table.deinit();

    var expected = [_]f32{ 0.25, -0.5, 0.75, -1.0, 1.25, -1.5, 1.75, -2.0, 2.25, -2.5, 2.75, -3.0, 3.25, -3.5, 3.75, -4.0 };
    var actual = expected;
    applyRopeSingleRow(&expected, 3, 2, 8, 10000.0);
    table.apply(&actual, 3, 2, 8);
    for (expected, actual) |want, got| {
        try std.testing.expectApproxEqAbs(want, got, 1e-6);
    }
}

test "projection worker reuses its thread and shuts down idle" {
    var worker: ProjectionWorker = undefined;
    try worker.init();
    var value: usize = 0;
    const task = struct {
        fn run(ptr: *anyopaque) void {
            const out: *usize = @ptrCast(@alignCast(ptr));
            out.* = 42;
        }
    }.run;
    worker.start(.{ .run = task, .args = @ptrCast(&value) });
    worker.wait();
    try std.testing.expectEqual(@as(usize, 42), value);
    worker.deinit();

    var idle: ProjectionWorker = undefined;
    try idle.init();
    idle.deinit();
}

test "decode thread selection respects asymmetric core topology" {
    try std.testing.expectEqual(
        @as(usize, 6),
        selectDecodeThreadCount(8, .{ .performance = 4, .efficiency = 4 }),
    );
    try std.testing.expectEqual(
        @as(usize, 5),
        selectDecodeThreadCount(6, .{ .performance = 4, .efficiency = 2 }),
    );
    try std.testing.expectEqual(@as(usize, 4), selectDecodeThreadCount(4, null));
    try std.testing.expectEqual(@as(usize, 8), selectDecodeThreadCount(16, null));
    // Invalid or virtualized topology metadata falls back to the safe cap.
    try std.testing.expectEqual(
        @as(usize, 8),
        selectDecodeThreadCount(8, .{ .performance = 8, .efficiency = 8 }),
    );
}

test "PairNibble rejects unsupported participant topology before execution" {
    for (1..9) |participants|
        try std.testing.expect(pairNibbleParticipantsSupported(
            .pair_nibble,
            participants,
        ));
    for ([_]usize{ 0, 9, std.math.maxInt(usize) }) |participants|
        try std.testing.expect(!pairNibbleParticipantsSupported(
            .pair_nibble,
            participants,
        ));
    try std.testing.expect(pairNibbleParticipantsSupported(.separate, 9));
}

test "parallel attention selection retains conservative serial fallbacks" {
    try std.testing.expectEqual(@as(?usize, null), default_parallel_attention_min_context);
    try std.testing.expect(!shouldParallelizeAttention(
        127,
        8,
        4,
        default_parallel_attention_min_context,
    ));
    try std.testing.expect(!shouldParallelizeAttention(
        128,
        8,
        4,
        default_parallel_attention_min_context,
    ));
    try std.testing.expect(!shouldParallelizeAttention(
        128,
        1,
        4,
        default_parallel_attention_min_context,
    ));
    try std.testing.expect(!shouldParallelizeAttention(
        128,
        8,
        1,
        default_parallel_attention_min_context,
    ));
    try std.testing.expect(!shouldParallelizeAttention(4096, 8, 4, null));

    // Primary p176+n64 decode graphs see 177..239 live KV rows: threshold 128
    // exercises every graph while 256/512 remain exact serial controls.
    try std.testing.expect(shouldParallelizeAttention(177, 8, 4, 128));
    try std.testing.expect(shouldParallelizeAttention(239, 8, 4, 128));
    try std.testing.expect(!shouldParallelizeAttention(239, 8, 4, 256));
    try std.testing.expect(!shouldParallelizeAttention(239, 8, 4, 512));
}

test "parallel attention telemetry accounts a late threshold crossing exactly" {
    const prompt_len: usize = 120;
    const decode_graphs: usize = 10;
    const layer_count: usize = 24;
    var telemetry: GenerationPhaseTelemetry = .{};

    for (0..decode_graphs) |graph_index| {
        const dispatches_before = telemetry.parallel_attention_dispatches;
        const context_len = prompt_len + graph_index + 1;
        if (shouldParallelizeAttention(
            context_len,
            14,
            6,
            128,
        )) {
            telemetry.parallel_attention_dispatches += layer_count;
        }
        try finishParallelAttentionGraph(&telemetry, dispatches_before, 0, 0, 0, layer_count);
    }

    // Contexts 121..127 stay serial; 128..130 contribute three graphs.
    try std.testing.expectEqual(@as(usize, 3), telemetry.parallel_attention_graphs);
    try std.testing.expectEqual(@as(usize, 3 * layer_count), telemetry.parallel_attention_dispatches);
}

test "parallel attention telemetry rejects partial and corrupt graph accounting" {
    const layer_count: usize = 24;

    var partial: GenerationPhaseTelemetry = .{
        .parallel_attention_dispatches = layer_count - 1,
    };
    try std.testing.expectError(
        GenerateError.ForwardFailed,
        finishParallelAttentionGraph(&partial, 0, 0, 0, 0, layer_count),
    );
    try std.testing.expectEqual(@as(usize, 0), partial.parallel_attention_graphs);

    var overfull: GenerationPhaseTelemetry = .{
        .parallel_attention_dispatches = layer_count + 1,
    };
    try std.testing.expectError(
        GenerateError.ForwardFailed,
        finishParallelAttentionGraph(&overfull, 0, 0, 0, 0, layer_count),
    );
    try std.testing.expectEqual(@as(usize, 0), overfull.parallel_attention_graphs);

    var exact: GenerationPhaseTelemetry = .{
        .parallel_attention_dispatches = layer_count,
    };
    try finishParallelAttentionGraph(&exact, 0, 0, 0, 0, layer_count);
    try std.testing.expectEqual(@as(usize, 1), exact.parallel_attention_graphs);
    // A later serial graph preserves the exact cumulative invariant.
    try finishParallelAttentionGraph(&exact, layer_count, 0, 0, 0, layer_count);
    try std.testing.expectEqual(@as(usize, 1), exact.parallel_attention_graphs);
    // Reusing the old boundary would double-close the same eligible graph.
    try std.testing.expectError(
        GenerateError.ForwardFailed,
        finishParallelAttentionGraph(&exact, 0, 0, 0, 0, layer_count),
    );

    var regressed: GenerationPhaseTelemetry = .{
        .parallel_attention_graphs = 1,
        .parallel_attention_dispatches = layer_count - 1,
    };
    try std.testing.expectError(
        GenerateError.ForwardFailed,
        finishParallelAttentionGraph(&regressed, layer_count, 0, 0, 0, layer_count),
    );
    try std.testing.expectError(
        GenerateError.ForwardFailed,
        finishParallelAttentionGraph(&exact, layer_count, 0, 0, 0, 0),
    );

    var exact_handoff: GenerationPhaseTelemetry = .{
        .parallel_attention_dispatches = layer_count,
        .handoff_dispatches = layer_count,
        .fused_gqa_dispatches = layer_count,
        .paired_mlp_dispatches = layer_count,
    };
    try finishParallelAttentionGraph(&exact_handoff, 0, 0, 0, 0, layer_count);
    try std.testing.expectEqual(@as(usize, 1), exact_handoff.parallel_attention_graphs);
    try std.testing.expectEqual(@as(usize, 1), exact_handoff.handoff_graphs);
    try std.testing.expectEqual(@as(usize, 1), exact_handoff.fused_gqa_graphs);
    try std.testing.expectEqual(@as(usize, 1), exact_handoff.paired_mlp_graphs);

    var partial_handoff: GenerationPhaseTelemetry = .{
        .parallel_attention_dispatches = layer_count,
        .handoff_dispatches = layer_count - 1,
    };
    try std.testing.expectError(
        GenerateError.ForwardFailed,
        finishParallelAttentionGraph(&partial_handoff, 0, 0, 0, 0, layer_count),
    );
    var impossible_handoff: GenerationPhaseTelemetry = .{
        .handoff_dispatches = layer_count,
    };
    try std.testing.expectError(
        GenerateError.ForwardFailed,
        finishParallelAttentionGraph(&impossible_handoff, 0, 0, 0, 0, layer_count),
    );
    var partial_fused: GenerationPhaseTelemetry = .{
        .parallel_attention_dispatches = layer_count,
        .handoff_dispatches = layer_count,
        .fused_gqa_dispatches = layer_count - 1,
    };
    try std.testing.expectError(
        GenerateError.ForwardFailed,
        finishParallelAttentionGraph(&partial_fused, 0, 0, 0, 0, layer_count),
    );
    var impossible_fused: GenerationPhaseTelemetry = .{
        .parallel_attention_dispatches = layer_count,
        .fused_gqa_dispatches = layer_count,
    };
    try std.testing.expectError(
        GenerateError.ForwardFailed,
        finishParallelAttentionGraph(&impossible_fused, 0, 0, 0, 0, layer_count),
    );
    var partial_paired_mlp: GenerationPhaseTelemetry = .{
        .parallel_attention_dispatches = layer_count,
        .handoff_dispatches = layer_count,
        .paired_mlp_dispatches = layer_count - 1,
    };
    try std.testing.expectError(
        GenerateError.ForwardFailed,
        finishParallelAttentionGraph(&partial_paired_mlp, 0, 0, 0, 0, layer_count),
    );
    var impossible_paired_mlp: GenerationPhaseTelemetry = .{
        .parallel_attention_dispatches = layer_count,
        .paired_mlp_dispatches = layer_count,
    };
    try std.testing.expectError(
        GenerateError.ForwardFailed,
        finishParallelAttentionGraph(&impossible_paired_mlp, 0, 0, 0, 0, layer_count),
    );
    var regressed_paired_mlp: GenerationPhaseTelemetry = .{
        .parallel_attention_graphs = 1,
        .parallel_attention_dispatches = layer_count,
        .handoff_graphs = 1,
        .handoff_dispatches = layer_count,
        .paired_mlp_graphs = 1,
        .paired_mlp_dispatches = layer_count - 1,
    };
    try std.testing.expectError(
        GenerateError.ForwardFailed,
        finishParallelAttentionGraph(
            &regressed_paired_mlp,
            layer_count,
            layer_count,
            0,
            layer_count,
            layer_count,
        ),
    );
}

test "generation rejects zero and mismatched model layer counts" {
    try validateModelLayerCount(24, 24);
    try std.testing.expectError(
        GenerateError.ShapeMismatch,
        validateModelLayerCount(0, 0),
    );
    try std.testing.expectError(
        GenerateError.ShapeMismatch,
        validateModelLayerCount(24, 23),
    );
    try std.testing.expectError(
        GenerateError.ShapeMismatch,
        validateModelLayerCount(23, 24),
    );
}

const ResourceCommitObserverTestContext = struct {
    calls: usize = 0,
    fail: bool = false,
    evidence_abi: u64 = 0,
    bank_abi: u64 = 0,
    receipt: ?resource_bank.Receipt = null,

    fn observe(
        raw_context: *anyopaque,
        evidence: *const ResourceCommitEvidenceV1,
    ) ResourceCommitObserverError!void {
        const self: *@This() = @ptrCast(@alignCast(raw_context));
        self.calls += 1;
        self.evidence_abi = evidence.abi;
        self.bank_abi = evidence.resource_bank_abi;
        self.receipt = evidence.receipt;
        if (self.fail) return error.Unavailable;
    }
};

test "resource commit observer is versioned lossless and fail closed" {
    const receipt: resource_bank.Receipt = .{
        .bank_epoch = 91,
        .slot_index = 3,
        .generation = 17,
        .owner_key = 0x1234,
        .claim = .{
            .capsule_bytes = 64,
            .kv_bytes = 4096,
            .activation_bytes = 512,
            .output_journal_bytes = 32,
            .queue_slots = 1,
        },
        .integrity = 0xabcd,
    };
    var context: ResourceCommitObserverTestContext = .{};
    const observer: ResourceCommitObserver = .{
        .context = &context,
        .observe = ResourceCommitObserverTestContext.observe,
    };

    try runResourceCommitObserver(observer, receipt);
    try std.testing.expectEqual(@as(usize, 1), context.calls);
    try std.testing.expectEqual(resource_commit_observer_abi, context.evidence_abi);
    try std.testing.expectEqual(request_resource_bank_abi, context.bank_abi);
    try std.testing.expect(std.meta.eql(receipt, context.receipt.?));

    context.fail = true;
    try std.testing.expectError(
        GenerateError.ResourceCommitObserverRejected,
        runResourceCommitObserver(observer, receipt),
    );
    try std.testing.expectEqual(@as(usize, 2), context.calls);

    const invalid_observer: ResourceCommitObserver = .{
        .abi = resource_commit_observer_abi + 1,
        .context = &context,
        .observe = ResourceCommitObserverTestContext.observe,
    };
    try std.testing.expectError(
        GenerateError.ResourceCommitObserverRejected,
        runResourceCommitObserver(invalid_observer, receipt),
    );
    try std.testing.expectEqual(@as(usize, 2), context.calls);
}

const TokenPublicationObserverTestContext = struct {
    calls: usize = 0,
    reject: bool = false,
    evidence: ?TokenPublicationEvidenceV1 = null,

    fn observe(
        raw_context: *anyopaque,
        evidence: *const TokenPublicationEvidenceV1,
    ) TokenPublicationObserverError!void {
        const self: *@This() = @ptrCast(@alignCast(raw_context));
        self.calls += 1;
        self.evidence = evidence.*;
        if (self.reject) return error.Unavailable;
    }
};

test "token publication observer is versioned contextual and fail closed" {
    var context: TokenPublicationObserverTestContext = .{};
    const observer: TokenPublicationObserver = .{
        .logical_request_index = 3,
        .context = &context,
        .observe = TokenPublicationObserverTestContext.observe,
    };
    try runTokenPublicationObserver(observer, 17, 91, true);
    try std.testing.expectEqual(@as(usize, 1), context.calls);
    try std.testing.expectEqual(token_publication_observer_abi, context.evidence.?.abi);
    try std.testing.expectEqual(@as(u32, 3), context.evidence.?.logical_request_index);
    try std.testing.expectEqual(@as(u64, 17), context.evidence.?.step_index);
    try std.testing.expectEqual(@as(u32, 91), context.evidence.?.token_id);
    try std.testing.expect(context.evidence.?.terminal);

    context.reject = true;
    try std.testing.expectError(
        GenerateError.TokenPublicationObserverRejected,
        runTokenPublicationObserver(observer, 18, 92, false),
    );
    try std.testing.expectEqual(@as(usize, 2), context.calls);

    const invalid: TokenPublicationObserver = .{
        .abi = token_publication_observer_abi + 1,
        .context = &context,
        .observe = TokenPublicationObserverTestContext.observe,
    };
    try std.testing.expectError(
        GenerateError.TokenPublicationObserverRejected,
        runTokenPublicationObserver(invalid, 0, 0, true),
    );
    try std.testing.expectEqual(@as(usize, 2), context.calls);
}
