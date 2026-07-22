//! Allocation-free persistent executor for packed INT4 decode projections.
//!
//! `std.Thread.Pool.spawnWg` is convenient, but cached decode submits several
//! thousand short-lived closures per generated token. This executor keeps a
//! fixed set of workers and broadcasts one batch containing all independent
//! projections that share a layer phase (Q/K/V or gate/up). Every participant
//! claims coarse output-row tiles from an atomic queue. This keeps the hot path
//! allocation-free while balancing heterogeneous CPU cores; tiles are
//! exclusively owned, so no output synchronization is required.

const std = @import("std");
const builtin = @import("builtin");
const tensor = @import("core").tensor;
const int4_weights = @import("int4_weights.zig");
const int4_matmul = @import("backends/cpu/int4_matmul.zig");
const kernels = @import("backends/cpu/kernels.zig");
const kv_cache = @import("kv_cache.zig");

const GreedyKernelResult = extern struct {
    value: f32,
    index: usize,
    valid: c_int,
    saw_nan: c_int,
};

comptime {
    std.debug.assert(@sizeOf(GreedyKernelResult) == 24);
    std.debug.assert(@offsetOf(GreedyKernelResult, "value") == 0);
    std.debug.assert(@offsetOf(GreedyKernelResult, "index") == 8);
    std.debug.assert(@offsetOf(GreedyKernelResult, "valid") == 16);
    std.debug.assert(@offsetOf(GreedyKernelResult, "saw_nan") == 20);
}

extern fn glacier_int4_matvec_neon_q8_prequant_f16scale_rows4_k16_v2(
    q_input: [*]const i8,
    activation_scales: [*]const f32,
    packed_weights: [*]const u8,
    scales: [*]const f16,
    bias: ?[*]const f32,
    output: ?[*]f32,
    out_features: usize,
    in_features: usize,
    group_size: usize,
    argmax: ?*GreedyKernelResult,
) c_int;

extern fn glacier_int4_matvec_neon_q8_prequant_f16scale_rows4_k16(
    q_input: [*]const i8,
    activation_scales: [*]const f32,
    packed_weights: [*]const u8,
    scales: [*]const f16,
    bias: ?[*]const f32,
    output: [*]f32,
    out_features: usize,
    in_features: usize,
    group_size: usize,
) void;

extern fn glacier_all_finite_f32_neon(
    values: [*]const f32,
    count: usize,
) c_int;

pub const Tensor = tensor.Tensor;
pub const TensorError = tensor.TensorError;

pub const Projection = struct {
    x: Tensor,
    weights: int4_weights.Int4WeightData,
    bias: []const f32,
    out: Tensor,
    out_f: usize,
    in_f: usize,
    use_q8: bool,
};

/// Typed dual-output MLP projection. PairNibble storage is intentionally not
/// representable as `Projection`/`Int4WeightData`, so no legacy single-output
/// kernel can consume its low/high-nibble branch encoding by accident.
pub const PairNibbleProjection = struct {
    x: Tensor,
    weights: int4_weights.PairNibbleWeightData,
    gate_bias: []const f32,
    up_bias: []const f32,
    gate_out: Tensor,
    up_out: Tensor,
    out_f: usize,
    in_f: usize,
};

/// Outputless M1 PairNibble producer. Gate/up values are confined to one
/// worker-private rows4 tile and immediately converted with the exact
/// SwiGLU-to-Q8 arithmetic consumed by a prepared down projection.
pub const PairNibbleSiluQ8Projection = struct {
    x: Tensor,
    weights: int4_weights.PairNibbleWeightData,
    gate_bias: []const f32,
    up_bias: []const f32,
    q_output: []i8,
    activation_scales: []f32,
    out_f: usize,
    in_f: usize,
    down_group_size: u32,
};

/// X-less consumer for an already prepared Q8 activation. Unlike the generic
/// `Projection`, this descriptor cannot pretend that a materialized f32 input
/// exists and cannot select a non-Q8 kernel. It is the only down descriptor
/// accepted by the single-epoch outputless PairNibble graph.
pub const PairNibblePreparedDownProjection = struct {
    weights: int4_weights.Int4WeightData,
    bias: []const f32,
    out: Tensor,
    out_f: usize,
    in_f: usize,
};

/// Successful PairNibble executor work only. Validation rejects and failed
/// worker epochs never advance these counters, which makes deltas suitable for
/// request-level evidence receipts rather than attempt accounting.
pub const PairNibbleTelemetry = struct {
    successful_runs: u64,
    activation_quantizations: u64,
    silu_q8_runs: u64,
    m1_runs: u64,
    m2_runs: u64,
    m3_runs: u64,
    m4_runs: u64,
    projected_rows: u64,
    row_shards: u64,
    last_tile_rows: u64,
    last_shard_count: u64,
};

/// Request-admitted ownership policy for the two private PairNibble producer
/// branches. `disabled` keeps ordinary executors allocation-free and makes the
/// outputless Pair APIs fail closed. The two enabled policies deliberately use
/// the same executor-owned arena so same-binary evidence changes capacity only.
pub const PairScratchPolicy = enum {
    disabled,
    fixed_256,
    model_shaped,
};

pub const PairGroupSet = struct {
    g8: bool = false,
    g16: bool = false,
};

pub const PairScratchSpec = struct {
    policy: PairScratchPolicy = .disabled,
    producer_groups: PairGroupSet = .{},
};

/// Exact maximum-concurrency capacity admitted before workers are started.
/// `selected_*_rows` follows Pair producer geometry; compact-frame/down groups
/// are an independent contract and must never influence this ledger.
pub const PairScratchLedger = struct {
    participants: usize,
    selected_g8_rows: usize,
    selected_g16_rows: usize,
    capacity_rows: usize,
    branch_stride_rows: usize,
    participant_stride_rows: usize,
    f32_elements: usize,
    bytes: usize,
    fixed_counterfactual_bytes: usize,
    reclaimed_bytes: usize,
};

pub const PairScratchTelemetry = struct {
    policy: PairScratchPolicy,
    ledger: PairScratchLedger,
    allocations: usize,
    fixed_dispatches: u64,
    model_shaped_dispatches: u64,
};

const PairScratchView = struct {
    backing: []f32,
    capacity_rows: usize,
    participant_stride_rows: usize,
};

/// Versioned process-local ABI for sealed packed-decode recipes. This is
/// deliberately independent of the on-disk runtime-image ABI: changing tile
/// geometry, activation grouping, barrier topology, or kernel interpretation
/// invalidates an execution plan even when model bytes remain compatible.
pub const sealed_handoff_abi: u64 = 0x4753_4850_0000_0004;

const SealedProjection = struct {
    plan: int4_matmul.BoundPreparedQ8MatvecPlan,
    tile_count: u32,
};

const SealedActivationSource = struct {
    input: [*]const f32,
    q_output: [*]i8,
    activation_scales: [*]f32,
    input_len: u32,
    scale_count: u32,
    group_size: u8,
};

const SealedPreparedSet = struct {
    g8: ?SealedActivationSource = null,
    g16: ?SealedActivationSource = null,
};

const Batch = struct {
    projections: []const Projection = &.{},
    sealed_projections: []const SealedProjection = &.{},
    sealed_sources: SealedPreparedSet = .{},
    next_tile: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    total_tiles: usize,
    prepared_g8: ?PreparedActivation = null,
    prepared_g16: ?PreparedActivation = null,
    force_prepared: bool = false,
    err: ?TensorError = null,
    test_tile_visits: if (builtin.is_test) ?[]std.atomic.Value(u32) else void =
        if (builtin.is_test) null else {},
};

const PairNibbleBatch = struct {
    plan: int4_matmul.BoundPreparedPairNibbleQ8Plan,
    next_shard: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    shard_count: usize,
    tile_rows: usize,
    err: ?TensorError = null,
    test_shard_visits: if (builtin.is_test) ?[]std.atomic.Value(u32) else void =
        if (builtin.is_test) null else {},
};

const PairNibbleSiluQ8Batch = struct {
    plan: int4_matmul.BoundPreparedPairNibbleQ8TilePlan,
    input: []const f32,
    input_q: []i8,
    input_scales: []f32,
    q_output: []i8,
    output_scales: []f32,
    down_group_size: u32,
    next_participant: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    participant_count: usize,
    shard_count: usize,
    tile_rows: usize,
    scratch: []f32,
    scratch_capacity_rows: usize,
    scratch_participant_stride_rows: usize,
    err: ?TensorError = null,
    test_shard_visits: if (builtin.is_test) ?[]std.atomic.Value(u32) else void =
        if (builtin.is_test) null else {},
};

const ValidatedPairNibbleSiluQ8Projection = struct {
    recipe: int4_matmul.PreparedPairNibbleQ8TilePlan,
    input: []const f32,
    q_output: []i8,
    output_scales: []f32,
    down_group_size: u32,
};

/// Type-erased, allocation-free task submitted to the persistent workers.
/// The context must remain alive until `parallelFor` returns. On success each
/// index in `[0, task_count)` is invoked exactly once; callers may safely share
/// output storage when each index owns a disjoint range.
pub const ParallelForFn = *const fn (context: *anyopaque, task_index: usize) TensorError!void;

/// Caller-owned bridge between the Q/K/V projection phase and disjoint
/// attention tasks. It runs exactly once on a graph coordinator after all Q/K/V
/// tiles are complete and before any attention task starts.
pub const HandoffBridgeFn = *const fn (context: *anyopaque) TensorError!void;

/// Proves that type-erased, per-token callback contexts still reference the
/// buffers and layer semantics captured while a sealed plan was prepared.
/// Implementations may admit dynamic position-dependent fields, but must
/// return the same key for the same static request-local binding.
pub const SealedHandoffBindingFn = *const fn (
    bridge_context: *anyopaque,
    attention_context: *anyopaque,
    mlp_bridge_context: *anyopaque,
    layer_index: usize,
    position: usize,
    attention_task_count: usize,
) TensorError!u64;

/// Projection phase whose Q8 activation is produced by the preceding bridge.
/// The slices are validated before dispatch but populated while workers wait at
/// the phase barrier.
pub const PreparedProjectionBatch = struct {
    projections: []const Projection,
    q_input: []const i8,
    activation_scales: []const f32,
    group_size: u32,
};

/// Optional disjoint task domain for a Handoff bridge whose output ranges are
/// independent. When present, all persistent participants help execute it in
/// place of the coordinator-only callback.
pub const ParallelBridge = struct {
    context: *anyopaque,
    task_count: usize,
    task: ParallelForFn,
};

pub const SerialBridge = struct {
    context: *anyopaque,
    task: HandoffBridgeFn,
};

/// Typed gate/up producer consumed immediately by SwiGLU-to-Q8. The executor
/// binds every mutable slice to `HandoffGraph.final`, validates the whole graph
/// before dispatch, and lets workers dynamically claim disjoint row stripes.
pub const PairedSiluQ8Bridge = struct {
    gate: Tensor,
    up: Tensor,
    q_output: []i8,
    activation_scales: []f32,
};

/// Exactly one final handoff policy is active. A tagged union prevents a
/// malformed graph from silently combining or ignoring serial, parallel, and
/// paired producers.
pub const FinalHandoff = union(enum) {
    serial: SerialBridge,
    parallel: ParallelBridge,
    paired_silu_q8: PairedSiluQ8Bridge,
};

/// A specialized full-layer decode subgraph executed under one
/// persistent-worker epoch. All referenced slices and contexts must remain
/// alive until the synchronous `runHandoffGraph` call returns. Bridges may
/// initialize later-phase contexts/activations, but must not recursively submit
/// work to this executor.
pub const HandoffGraph = struct {
    qkv: []const Projection,
    bridge_context: *anyopaque,
    bridge: HandoffBridgeFn,
    attention_context: *anyopaque,
    attention_task_count: usize,
    attention_task: ParallelForFn,
    output: []const Projection,
    mlp_bridge_context: *anyopaque,
    mlp_bridge: HandoffBridgeFn,
    mlp: []const Projection,
    final_handoff: FinalHandoff,
    final: PreparedProjectionBatch,
    sealed_position: usize = 0,
    sealed_binding: ?SealedHandoffBindingFn = null,
};

/// Static, request-local execution plan for the production packed decode
/// topology. It copies only normalized slices, scalar geometry, and function
/// pointers; stack-backed Tensor shapes, Projection arrays, and callback
/// contexts are never retained. Treat a prepared plan as immutable.
pub const SealedHandoffPlan = struct {
    abi: u64,
    integrity: u64,
    storage_address: usize,
    admission_token: u64,
    executor_address: usize,
    executor_instance: u64,
    participants: usize,
    layer_index: usize,
    qkv: [3]SealedProjection,
    qkv_tiles: usize,
    qkv_sources: SealedPreparedSet,
    bridge: HandoffBridgeFn,
    attention_task: ParallelForFn,
    attention_task_count: usize,
    binding: SealedHandoffBindingFn,
    binding_key: u64,
    output: [1]SealedProjection,
    output_tiles: usize,
    output_sources: SealedPreparedSet,
    mlp_bridge: HandoffBridgeFn,
    mlp: [2]SealedProjection,
    mlp_tiles: usize,
    mlp_sources: SealedPreparedSet,
    paired_mlp_plan: kernels.SiluMulQuantizeQ8Plan,
    final: [1]SealedProjection,
    final_tiles: usize,
};

/// Per-token state admitted by a sealed plan. Static descriptors cannot be
/// swapped at dispatch time; only checked stack-local callback contexts enter
/// the synchronous worker epoch.
pub const SealedHandoffInvocation = struct {
    layer_index: usize,
    position: usize,
    bridge_context: *anyopaque,
    attention_context: *anyopaque,
    attention_task_count: usize,
    mlp_bridge_context: *anyopaque,
};

const ValidatedHandoffGraph = struct {
    qkv_tiles: usize,
    output_tiles: usize,
    mlp_tiles: usize,
    final_tiles: usize,
    final_prepared: PreparedSet,
    serial_final_bridge: ?SerialBridge,
    parallel_final_bridge: ?ParallelForBatch,
    paired_mlp_plan: ?kernels.SiluMulQuantizeQ8Plan,
};

const ParallelForBatch = struct {
    context: *anyopaque,
    task: ParallelForFn,
    task_count: usize,
    next_task: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    err: ?TensorError = null,
};

/// Request-local sense barrier. Participants spin briefly, park only while a
/// serial completion is in flight, and otherwise yield across short imbalanced
/// tiles. Every graph stage reaches every barrier even after an error,
/// preventing a malformed task from stranding the persistent workers.
const PhaseBarrier = struct {
    participants: usize,
    arrived: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    phase: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn init(participants: usize) PhaseBarrier {
        return .{ .participants = participants };
    }

    /// One-phase rendezvous without a serial completion. This is used by
    /// compact producer/consumer epochs that publish all prepared activation
    /// bytes before any participant may enter the consumer kernel.
    fn wait(self: *PhaseBarrier) void {
        const phase = self.phase.load(.acquire);
        const arrived = self.arrived.fetchAdd(1, .acq_rel);
        std.debug.assert(arrived < self.participants);
        if (arrived + 1 == self.participants) {
            self.arrived.store(0, .monotonic);
            self.phase.store(phase +% 1, .release);
            return;
        }
        var spins: usize = 0;
        while (self.phase.load(.acquire) == phase) : (spins +%= 1) {
            if (spins < 1024) {
                std.atomic.spinLoopHint();
            } else {
                std.Thread.yield() catch {};
            }
        }
    }

    /// Rendezvous every graph participant and let the last arrival perform the
    /// serial completion which publishes the next phase's inputs. Completion
    /// catches and records its own errors before returning, so the release of
    /// `phase` cannot let a peer enter later work before `failed` is visible.
    /// The last arrival always advances the phase, including after an error;
    /// this preserves the graph's drain-on-failure contract.
    fn waitWithCompletion(
        self: *PhaseBarrier,
        graph: *HandoffGraphContext,
        local_err: *?TensorError,
        comptime completion: ?*const fn (*HandoffGraphContext, *?TensorError) void,
        comptime park_for_completion: bool,
    ) void {
        const phase = self.phase.load(.acquire);
        const arrived = self.arrived.fetchAdd(1, .acq_rel);
        std.debug.assert(arrived < self.participants);
        if (arrived + 1 == self.participants) {
            defer {
                self.arrived.store(0, .monotonic);
                self.phase.store(phase +% 1, .release);
                if (park_for_completion) {
                    std.Thread.Futex.wake(
                        &self.phase,
                        @intCast(self.participants - 1),
                    );
                }
            }
            if (completion) |complete| complete(graph, local_err);
            return;
        }

        var spins: usize = 0;
        while (self.phase.load(.acquire) == phase) : (spins +%= 1) {
            const spin_limit = if (park_for_completion) 512 else 1024;
            if (spins < spin_limit) {
                std.atomic.spinLoopHint();
            } else if (park_for_completion) {
                std.Thread.Futex.wait(&self.phase, phase);
            } else {
                std.Thread.yield() catch {};
            }
        }
    }
};

const HandoffGraphContext = struct {
    executor: *Executor,
    qkv: Batch,
    bridge_context: *anyopaque,
    bridge: HandoffBridgeFn,
    attention: ParallelForBatch,
    output: Batch,
    mlp_bridge_context: *anyopaque,
    mlp_bridge: HandoffBridgeFn,
    mlp: Batch,
    paired_mlp_plan: ?kernels.SiluMulQuantizeQ8Plan,
    serial_final_bridge: ?SerialBridge,
    parallel_final_bridge: ?ParallelForBatch,
    final: Batch,
    barrier: PhaseBarrier,
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn hasFailed(self: *const HandoffGraphContext) bool {
        return self.failed.load(.acquire);
    }

    fn recordError(self: *HandoffGraphContext, local_err: *?TensorError, err: TensorError) void {
        if (local_err.* == null) local_err.* = err;
        self.failed.store(true, .release);
    }

    fn completeQkv(self: *HandoffGraphContext, local_err: *?TensorError) void {
        if (!self.hasFailed())
            self.bridge(self.bridge_context) catch |err| self.recordError(local_err, err);
    }

    fn completeAttention(self: *HandoffGraphContext, local_err: *?TensorError) void {
        if (self.hasFailed()) return;
        if (self.output.sealed_projections.len != 0) {
            quantizeSealedSources(self.output.sealed_sources) catch |err| {
                self.recordError(local_err, err);
            };
            return;
        }
        const prepared_result = self.executor.prepareSharedActivations(
            self.output.projections,
        );
        if (prepared_result) |prepared| {
            self.output.prepared_g8 = prepared.g8;
            self.output.prepared_g16 = prepared.g16;
        } else |err| {
            self.recordError(local_err, err);
        }
    }

    fn completeOutput(self: *HandoffGraphContext, local_err: *?TensorError) void {
        if (!self.hasFailed())
            self.mlp_bridge(self.mlp_bridge_context) catch |err| self.recordError(local_err, err);
        if (self.hasFailed()) return;
        if (self.mlp.sealed_projections.len != 0) {
            quantizeSealedSources(self.mlp.sealed_sources) catch |err| {
                self.recordError(local_err, err);
            };
            return;
        }
        const prepared_result = self.executor.prepareSharedActivations(
            self.mlp.projections,
        );
        if (prepared_result) |prepared| {
            self.mlp.prepared_g8 = prepared.g8;
            self.mlp.prepared_g16 = prepared.g16;
        } else |err| {
            self.recordError(local_err, err);
        }
    }

    fn completeMlp(self: *HandoffGraphContext, local_err: *?TensorError) void {
        // A parallel final bridge needs every participant after this release.
        // The compatibility bridge is serial, so run it as this phase's
        // completion and avoid an otherwise empty rendezvous.
        if (self.serial_final_bridge) |bridge| {
            if (!self.hasFailed())
                bridge.task(bridge.context) catch |err| self.recordError(local_err, err);
        }
    }

    fn run(raw_context: *anyopaque, _: usize) TensorError!void {
        const self: *@This() = @ptrCast(@alignCast(raw_context));
        var local_err: ?TensorError = null;

        if (!self.hasFailed())
            runBatchWorker(&self.qkv) catch |err| self.recordError(&local_err, err);
        self.barrier.waitWithCompletion(self, &local_err, completeQkv, true);

        if (!self.hasFailed())
            runGraphParallelWorker(
                &self.attention,
                self.barrier.participants,
            ) catch |err| self.recordError(&local_err, err);
        self.barrier.waitWithCompletion(self, &local_err, completeAttention, true);

        if (!self.hasFailed())
            runBatchWorker(&self.output) catch |err| self.recordError(&local_err, err);
        self.barrier.waitWithCompletion(self, &local_err, completeOutput, true);

        if (!self.hasFailed()) {
            if (self.paired_mlp_plan) |plan| {
                runPairedProjectionWorker(&self.mlp, plan) catch |err|
                    self.recordError(&local_err, err);
            } else {
                runBatchWorker(&self.mlp) catch |err| self.recordError(&local_err, err);
            }
        }
        self.barrier.waitWithCompletion(self, &local_err, completeMlp, false);

        if (self.parallel_final_bridge) |*bridge| {
            if (!self.hasFailed())
                runGraphParallelWorker(
                    bridge,
                    self.barrier.participants,
                ) catch |err| self.recordError(&local_err, err);
            self.barrier.waitWithCompletion(self, &local_err, null, false);
        }

        if (!self.hasFailed())
            runBatchWorker(&self.final) catch |err| self.recordError(&local_err, err);
        // Typed paired graphs have already assigned one outer task to every
        // participant. The synchronous executor join drains all final workers,
        // so an internal terminal rendezvous would only burn tail CPU.
        if (self.paired_mlp_plan == null)
            self.barrier.waitWithCompletion(self, &local_err, null, false);

        // Parallel-final graphs use six rendezvous; serial graphs use five;
        // typed paired graphs fuse the producer and terminal join into four.
        const expected_phase: u32 = if (self.parallel_final_bridge != null)
            6
        else if (self.paired_mlp_plan != null)
            4
        else
            5;
        std.debug.assert(self.barrier.phase.load(.acquire) == expected_phase);

        if (local_err) |err| return err;
    }
};

/// PairNibble producer and prepared down projection executed under one worker
/// broadcast. The barrier is the only publication edge: it preserves the
/// existing complete-Q8 down kernel and therefore its accumulation order.
const PairDownEpochContext = struct {
    producer: PairNibbleSiluQ8Batch,
    down: Batch,
    barrier: PhaseBarrier,
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn recordError(self: *@This(), local_err: *?TensorError, err: TensorError) void {
        if (local_err.* == null) local_err.* = err;
        self.failed.store(true, .release);
    }

    fn run(raw_context: *anyopaque, _: usize) TensorError!void {
        const self: *@This() = @ptrCast(@alignCast(raw_context));
        var local_err: ?TensorError = null;
        if (!self.failed.load(.acquire))
            runPairNibbleSiluQ8BatchWorker(&self.producer) catch |err|
                self.recordError(&local_err, err);
        self.barrier.wait();
        if (!self.failed.load(.acquire))
            runSealedBatchWorker(&self.down) catch |err|
                self.recordError(&local_err, err);
        if (local_err) |err| return err;
    }
};

const WorkItem = union(enum) {
    projections: *Batch,
    pair_nibble: *PairNibbleBatch,
    pair_nibble_silu_q8: *PairNibbleSiluQ8Batch,
    parallel_for: *ParallelForBatch,
};

const tile_rows: usize = 64;
const paired_tile_rows: usize = 256;
const greedy_argmax_tile_rows: usize = 64;
pub const max_shared_input: usize = 16384;
pub const greedy_argmax_abi: u64 = 0x474c_4d48_0000_0002;
pub const greedy_eligibility_abi: u64 = 0x474c_5649_0000_0001;
/// Process-local execution contract for PairNibble scheduling and telemetry.
/// This is independent of `int4_weights.pair_nibble_abi`, which describes the
/// persistent byte representation rather than worker ownership semantics.
pub const pair_nibble_executor_abi: u64 = 0x4750_4e45_0000_0005;
pub const pair_scratch_abi: u64 = 0x4750_4e53_0000_0001;

/// Evidence-selected PairNibble row ownership. Measured configurations bind
/// directly to the retained full-Qwen Apple M1 campaign. Unmeasured counts use
/// the nearest measured participant count, with ties selecting the lower count.
/// Pair execution fails closed above eight participants until that topology has
/// retained same-machine evidence.
pub fn pairNibbleTileRows(
    participants: usize,
    group_size: usize,
) TensorError!usize {
    if (group_size != 8 and group_size != 16)
        return TensorError.ShapeMismatch;
    return switch (participants) {
        1 => 256,
        2 => if (group_size == 8) 32 else 64,
        3 => if (group_size == 8) 32 else 64,
        4 => if (group_size == 8) 64 else 128,
        5...6 => if (group_size == 8) 64 else 128,
        7 => 256,
        8 => 256,
        else => return TensorError.ShapeMismatch,
    };
}

fn checkedPairScratchBytes(elements: usize) TensorError!usize {
    return std.math.mul(usize, elements, @sizeOf(f32)) catch
        TensorError.ShapeMismatch;
}

/// Derive the complete private Pair tile allocation without consulting model
/// dimensions or down-projection geometry. This function is the admission
/// oracle shared by generation, executor initialization, tests, and evidence.
pub fn derivePairScratchLedger(
    participants: usize,
    spec: PairScratchSpec,
) TensorError!PairScratchLedger {
    const has_groups = spec.producer_groups.g8 or spec.producer_groups.g16;
    if (spec.policy == .disabled) {
        if (has_groups) return TensorError.ShapeMismatch;
        return .{
            .participants = participants,
            .selected_g8_rows = 0,
            .selected_g16_rows = 0,
            .capacity_rows = 0,
            .branch_stride_rows = 0,
            .participant_stride_rows = 0,
            .f32_elements = 0,
            .bytes = 0,
            .fixed_counterfactual_bytes = 0,
            .reclaimed_bytes = 0,
        };
    }
    if (!has_groups or participants == 0 or participants > 8)
        return TensorError.ShapeMismatch;

    const selected_g8_rows = if (spec.producer_groups.g8)
        try pairNibbleTileRows(participants, 8)
    else
        0;
    const selected_g16_rows = if (spec.producer_groups.g16)
        try pairNibbleTileRows(participants, 16)
    else
        0;
    const selected_rows = @max(selected_g8_rows, selected_g16_rows);
    const capacity_rows = switch (spec.policy) {
        .disabled => unreachable,
        .fixed_256 => paired_tile_rows,
        .model_shaped => selected_rows,
    };
    if (selected_rows == 0 or capacity_rows < selected_rows or
        capacity_rows > paired_tile_rows)
        return TensorError.ShapeMismatch;

    const participant_stride_rows = std.math.mul(
        usize,
        capacity_rows,
        2,
    ) catch return TensorError.ShapeMismatch;
    const f32_elements = std.math.mul(
        usize,
        participants,
        participant_stride_rows,
    ) catch return TensorError.ShapeMismatch;
    const bytes = try checkedPairScratchBytes(f32_elements);
    const fixed_elements = std.math.mul(
        usize,
        participants,
        2 * paired_tile_rows,
    ) catch return TensorError.ShapeMismatch;
    const fixed_bytes = try checkedPairScratchBytes(fixed_elements);
    if (bytes > fixed_bytes) return TensorError.ShapeMismatch;
    return .{
        .participants = participants,
        .selected_g8_rows = selected_g8_rows,
        .selected_g16_rows = selected_g16_rows,
        .capacity_rows = capacity_rows,
        .branch_stride_rows = capacity_rows,
        .participant_stride_rows = participant_stride_rows,
        .f32_elements = f32_elements,
        .bytes = bytes,
        .fixed_counterfactual_bytes = fixed_bytes,
        .reclaimed_bytes = fixed_bytes - bytes,
    };
}

/// Exact result for a caller-certified eligible vocabulary. Bits outside the
/// set are never candidates; zero rows4 tiles are skipped before projection.
/// `producer_rows` counts the rows actually dotted, including at most three
/// ineligible neighbors for each non-empty rows4 tile.
pub const EligibleGreedyResult = struct {
    token_index: usize,
    eligible_rows: usize,
    producer_rows: usize,
    skipped_rows: usize,
    overcomputed_rows: usize,
    producer_runs: usize,
    /// Maximum private rows4 output scratch across all participants. It is a
    /// bounded stack-frame requirement, not a full-vocabulary allocation.
    tile_scratch_bytes: usize,
};

pub const ExecutorOptions = struct {
    /// Allocate bounded per-participant candidates for an exact producer-side
    /// greedy reduction that never materializes logits, including tile output.
    greedy_argmax: bool = false,
    /// Disabled by default so conventional/separate executors do not acquire
    /// Pair-only resources. Generation supplies an all-layer admitted spec.
    pair_scratch: PairScratchSpec = .{},
};

pub fn greedyArgmaxScratchBytesForParticipants(
    participants: usize,
) TensorError!usize {
    if (participants == 0) return TensorError.ShapeMismatch;
    return std.math.mul(
        usize,
        participants,
        @sizeOf(GreedyArgmaxCandidate),
    ) catch TensorError.ShapeMismatch;
}

const GreedyArgmaxCandidate = struct {
    value: f32 = -std.math.inf(f32),
    index: usize = std.math.maxInt(usize),
    valid: bool = false,
};

/// Exact caller-allocator payload created by `Executor.initWithOptions`.
/// Inline executor fields, allocator metadata/alignment, OS thread state, and
/// worker stacks are deliberately outside this logical ledger.
pub const ExecutorLogicalLedger = struct {
    participants: usize,
    worker_thread_handles_bytes: usize,
    greedy_argmax_bytes: usize,
    pair_scratch: PairScratchLedger,
    allocation_payload_bytes: usize,
};

pub fn deriveExecutorLogicalLedger(
    participants: usize,
    options: ExecutorOptions,
) TensorError!ExecutorLogicalLedger {
    if (participants == 0) return TensorError.ShapeMismatch;
    const worker_thread_handles_bytes = std.math.mul(
        usize,
        participants - 1,
        @sizeOf(std.Thread),
    ) catch return TensorError.ShapeMismatch;
    const greedy_argmax_bytes = if (options.greedy_argmax)
        try greedyArgmaxScratchBytesForParticipants(participants)
    else
        0;
    const pair_ledger = try derivePairScratchLedger(
        participants,
        options.pair_scratch,
    );
    const scratch_bytes = std.math.add(
        usize,
        greedy_argmax_bytes,
        pair_ledger.bytes,
    ) catch return TensorError.ShapeMismatch;
    const allocation_payload_bytes = std.math.add(
        usize,
        worker_thread_handles_bytes,
        scratch_bytes,
    ) catch return TensorError.ShapeMismatch;
    return .{
        .participants = participants,
        .worker_thread_handles_bytes = worker_thread_handles_bytes,
        .greedy_argmax_bytes = greedy_argmax_bytes,
        .pair_scratch = pair_ledger,
        .allocation_payload_bytes = allocation_payload_bytes,
    };
}

const PreparedActivation = struct {
    q_input: []const i8,
    scales: []const f32,
};

const PreparedSet = struct {
    g8: ?PreparedActivation = null,
    g16: ?PreparedActivation = null,
};

const GreedyArgmaxGeometry = struct {
    tile_count: usize,
    packed_bytes_per_row: usize,
    scales_per_row: usize,
};

const GreedyArgmaxContext = struct {
    q_input: [*]const i8,
    activation_scales: [*]const f32,
    packed_weights: [*]const u8,
    scales: [*]const f16,
    candidates: []GreedyArgmaxCandidate,
    out_f: usize,
    in_f: usize,
    group_size: usize,
    tile_count: usize,
    packed_bytes_per_row: usize,
    scales_per_row: usize,
    next_tile: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    saw_nan: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(raw_context: *anyopaque, task_index: usize) TensorError!void {
        const self: *@This() = @ptrCast(@alignCast(raw_context));
        if (task_index >= self.candidates.len)
            return TensorError.ShapeMismatch;
        var local: GreedyArgmaxCandidate = .{};
        while (true) {
            const tile_index = self.next_tile.fetchAdd(1, .monotonic);
            if (tile_index >= self.tile_count) break;
            const row_start = std.math.mul(
                usize,
                tile_index,
                greedy_argmax_tile_rows,
            ) catch return TensorError.ShapeMismatch;
            const row_limit = std.math.add(
                usize,
                row_start,
                greedy_argmax_tile_rows,
            ) catch self.out_f;
            const row_end = @min(row_limit, self.out_f);
            if (row_start >= row_end or row_start % 4 != 0 or row_end % 4 != 0)
                return TensorError.ShapeMismatch;
            const packed_start = std.math.mul(
                usize,
                row_start,
                self.packed_bytes_per_row,
            ) catch return TensorError.ShapeMismatch;
            const scale_start = std.math.mul(
                usize,
                row_start,
                self.scales_per_row,
            ) catch return TensorError.ShapeMismatch;
            const row_count = row_end - row_start;
            var tile_result: GreedyKernelResult = undefined;
            if (glacier_int4_matvec_neon_q8_prequant_f16scale_rows4_k16_v2(
                self.q_input,
                self.activation_scales,
                self.packed_weights + packed_start,
                self.scales + scale_start,
                null,
                null,
                row_count,
                self.in_f,
                self.group_size,
                &tile_result,
            ) == 0 or tile_result.saw_nan != 0 or tile_result.valid == 0) {
                self.saw_nan.store(true, .release);
                continue;
            }
            if (tile_result.index >= row_count) return TensorError.ShapeMismatch;
            updateGreedyCandidate(
                &local,
                tile_result.value,
                std.math.add(usize, row_start, tile_result.index) catch
                    return TensorError.ShapeMismatch,
            );
        }
        self.candidates[task_index] = local;
    }
};

const EligibleGreedyContext = struct {
    q_input: [*]const i8,
    activation_scales: [*]const f32,
    packed_weights: [*]const u8,
    scales: [*]const f16,
    eligible_words: []const u64,
    candidates: []GreedyArgmaxCandidate,
    out_f: usize,
    in_f: usize,
    group_size: usize,
    tile_count: usize,
    packed_bytes_per_row: usize,
    scales_per_row: usize,
    next_tile: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    producer_rows: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    producer_runs: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    saw_nan: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(raw_context: *anyopaque, task_index: usize) TensorError!void {
        const self: *@This() = @ptrCast(@alignCast(raw_context));
        if (task_index >= self.candidates.len)
            return TensorError.ShapeMismatch;
        var local: GreedyArgmaxCandidate = .{};
        var local_producer_rows: usize = 0;
        var local_producer_runs: usize = 0;
        var tile_output: [greedy_argmax_tile_rows]f32 = undefined;
        while (true) {
            const tile_index = self.next_tile.fetchAdd(1, .monotonic);
            if (tile_index >= self.tile_count) break;
            const row_start = std.math.mul(
                usize,
                tile_index,
                greedy_argmax_tile_rows,
            ) catch return TensorError.ShapeMismatch;
            const row_end = @min(
                std.math.add(
                    usize,
                    row_start,
                    greedy_argmax_tile_rows,
                ) catch self.out_f,
                self.out_f,
            );
            const row_count = row_end - row_start;
            if (row_count == 0 or row_count % 4 != 0 or
                tile_index >= self.eligible_words.len)
                return TensorError.ShapeMismatch;
            const valid_bits: u64 = if (row_count == 64)
                std.math.maxInt(u64)
            else
                (@as(u64, 1) << @intCast(row_count)) - 1;
            const eligible = self.eligible_words[tile_index] & valid_bits;
            if (eligible == 0) continue;

            if (eligible == valid_bits) {
                const packed_start = std.math.mul(
                    usize,
                    row_start,
                    self.packed_bytes_per_row,
                ) catch return TensorError.ShapeMismatch;
                const scale_start = std.math.mul(
                    usize,
                    row_start,
                    self.scales_per_row,
                ) catch return TensorError.ShapeMismatch;
                var result: GreedyKernelResult = undefined;
                if (glacier_int4_matvec_neon_q8_prequant_f16scale_rows4_k16_v2(
                    self.q_input,
                    self.activation_scales,
                    self.packed_weights + packed_start,
                    self.scales + scale_start,
                    null,
                    null,
                    row_count,
                    self.in_f,
                    self.group_size,
                    &result,
                ) == 0 or result.saw_nan != 0 or result.valid == 0) {
                    self.saw_nan.store(true, .release);
                    continue;
                }
                if (result.index >= row_count)
                    return TensorError.ShapeMismatch;
                updateGreedyCandidate(
                    &local,
                    result.value,
                    std.math.add(usize, row_start, result.index) catch
                        return TensorError.ShapeMismatch,
                );
                local_producer_rows = std.math.add(
                    usize,
                    local_producer_rows,
                    row_count,
                ) catch return TensorError.ShapeMismatch;
                local_producer_runs = std.math.add(
                    usize,
                    local_producer_runs,
                    1,
                ) catch return TensorError.ShapeMismatch;
                continue;
            }

            var rows4_index: usize = 0;
            while (rows4_index < row_count / 4) {
                const nibble_shift: u6 = @intCast(rows4_index * 4);
                if ((eligible >> nibble_shift) & 0x0f == 0) {
                    rows4_index += 1;
                    continue;
                }
                const run_start_tile = rows4_index;
                rows4_index += 1;
                while (rows4_index < row_count / 4) : (rows4_index += 1) {
                    const shift: u6 = @intCast(rows4_index * 4);
                    if ((eligible >> shift) & 0x0f == 0) break;
                }
                const local_row_start = std.math.mul(
                    usize,
                    run_start_tile,
                    4,
                ) catch return TensorError.ShapeMismatch;
                const local_row_end = std.math.mul(
                    usize,
                    rows4_index,
                    4,
                ) catch return TensorError.ShapeMismatch;
                const global_row_start = std.math.add(
                    usize,
                    row_start,
                    local_row_start,
                ) catch return TensorError.ShapeMismatch;
                const packed_start = std.math.mul(
                    usize,
                    global_row_start,
                    self.packed_bytes_per_row,
                ) catch return TensorError.ShapeMismatch;
                const scale_start = std.math.mul(
                    usize,
                    global_row_start,
                    self.scales_per_row,
                ) catch return TensorError.ShapeMismatch;
                glacier_int4_matvec_neon_q8_prequant_f16scale_rows4_k16(
                    self.q_input,
                    self.activation_scales,
                    self.packed_weights + packed_start,
                    self.scales + scale_start,
                    null,
                    tile_output[local_row_start..].ptr,
                    local_row_end - local_row_start,
                    self.in_f,
                    self.group_size,
                );
                local_producer_rows = std.math.add(
                    usize,
                    local_producer_rows,
                    local_row_end - local_row_start,
                ) catch return TensorError.ShapeMismatch;
                local_producer_runs = std.math.add(
                    usize,
                    local_producer_runs,
                    1,
                ) catch return TensorError.ShapeMismatch;

                for (local_row_start..local_row_end) |local_row| {
                    const bit: u6 = @intCast(local_row);
                    if ((eligible >> bit) & 1 == 0) continue;
                    const value = tile_output[local_row];
                    if (std.math.isNan(value)) {
                        self.saw_nan.store(true, .release);
                        continue;
                    }
                    updateGreedyCandidate(
                        &local,
                        value,
                        std.math.add(usize, row_start, local_row) catch
                            return TensorError.ShapeMismatch,
                    );
                }
            }
        }
        _ = self.producer_rows.fetchAdd(local_producer_rows, .monotonic);
        _ = self.producer_runs.fetchAdd(local_producer_runs, .monotonic);
        self.candidates[task_index] = local;
    }
};

fn updateGreedyCandidate(
    candidate: *GreedyArgmaxCandidate,
    value: f32,
    index: usize,
) void {
    if (!candidate.valid or value > candidate.value or
        (value == candidate.value and index < candidate.index))
    {
        candidate.* = .{ .value = value, .index = index, .valid = true };
    }
}

var next_executor_instance = std.atomic.Value(u64).init(1);

fn atomicSaturatingAdd(counter: *std.atomic.Value(u64), increment: u64) void {
    var current = counter.load(.monotonic);
    while (true) {
        const next = std.math.add(u64, current, increment) catch
            std.math.maxInt(u64);
        if (counter.cmpxchgWeak(
            current,
            next,
            .monotonic,
            .monotonic,
        )) |observed| {
            current = observed;
        } else {
            return;
        }
    }
}

fn reserveExecutorInstance(counter: *std.atomic.Value(u64)) TensorError!u64 {
    var current = counter.load(.monotonic);
    while (true) {
        if (current == std.math.maxInt(u64)) return TensorError.OutOfMemory;
        if (counter.cmpxchgWeak(
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

fn validatePreparedActivations(
    projections: []const Projection,
    q_input: []const i8,
    activation_scales: []const f32,
    group_size: u32,
) TensorError!PreparedSet {
    if (group_size != 8 and group_size != 16) return TensorError.ShapeMismatch;
    for (projections) |projection| {
        if (!projection.use_q8 or projection.weights.group_size != group_size or
            q_input.len < projection.in_f or
            activation_scales.len < int4_matmul.q8ActivationScaleCount(
                projection.in_f,
                group_size,
            ))
            return TensorError.ShapeMismatch;
    }
    const activation: PreparedActivation = .{
        .q_input = q_input,
        .scales = activation_scales,
    };
    return if (group_size == 8)
        .{ .g8 = activation }
    else
        .{ .g16 = activation };
}

fn validateParallelTaskCount(task_count: usize, participants: usize) TensorError!void {
    if (participants == 0) return TensorError.ShapeMismatch;
    const max_safe = std.math.sub(
        usize,
        std.math.maxInt(usize),
        participants,
    ) catch return TensorError.ShapeMismatch;
    if (task_count > max_safe) return TensorError.ShapeMismatch;
}

pub const Executor = struct {
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    instance_id: u64,
    mutex: std.Thread.Mutex = .{},
    work: std.Thread.Condition = .{},
    done: std.Thread.Condition = .{},
    generation: usize = 0,
    completed: usize = 0,
    current: ?WorkItem = null,
    stopping: bool = false,
    submission_lease: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    shared_q8_g8: [max_shared_input]i8 = undefined,
    shared_q8_g16: [max_shared_input]i8 = undefined,
    shared_scales_g8: [max_shared_input / 32]f32 = undefined,
    shared_scales_g16: [max_shared_input / 16]f32 = undefined,
    greedy_argmax_candidates: []GreedyArgmaxCandidate,
    pair_scratch_policy: PairScratchPolicy,
    pair_scratch_ledger: PairScratchLedger,
    pair_scratch_backing: ?[]align(64) f32,
    pair_successful_runs: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pair_activation_quantizations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pair_silu_q8_runs: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pair_m1_runs: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pair_m2_runs: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pair_m3_runs: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pair_m4_runs: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pair_projected_rows: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pair_row_shards: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pair_last_tile_rows: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pair_last_shard_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// `num_threads` includes the caller. One selects the synchronous path.
    pub fn init(self: *Executor, allocator: std.mem.Allocator, num_threads: usize) !void {
        return self.initWithOptions(allocator, num_threads, .{});
    }

    pub fn initWithOptions(
        self: *Executor,
        allocator: std.mem.Allocator,
        num_threads: usize,
        options: ExecutorOptions,
    ) !void {
        if (num_threads == 0) return TensorError.ShapeMismatch;
        const instance_id = try reserveExecutorInstance(&next_executor_instance);
        const logical_ledger = try deriveExecutorLogicalLedger(
            num_threads,
            options,
        );
        const pair_scratch_ledger = logical_ledger.pair_scratch;
        var pair_scratch_backing: ?[]align(64) f32 = null;
        if (pair_scratch_ledger.f32_elements != 0) {
            pair_scratch_backing = try allocator.alignedAlloc(
                f32,
                .@"64",
                pair_scratch_ledger.f32_elements,
            );
        }
        errdefer if (pair_scratch_backing) |backing| allocator.free(backing);
        const worker_count = logical_ledger.participants - 1;
        const threads = try allocator.alloc(std.Thread, worker_count);
        errdefer allocator.free(threads);
        var greedy_candidates: []GreedyArgmaxCandidate =
            @constCast((&[_]GreedyArgmaxCandidate{})[0..]);
        if (options.greedy_argmax) {
            greedy_candidates = try allocator.alloc(GreedyArgmaxCandidate, num_threads);
        }
        errdefer if (greedy_candidates.len != 0)
            allocator.free(greedy_candidates);
        self.* = .{
            .allocator = allocator,
            .threads = threads,
            .instance_id = instance_id,
            .greedy_argmax_candidates = greedy_candidates,
            .pair_scratch_policy = options.pair_scratch.policy,
            .pair_scratch_ledger = pair_scratch_ledger,
            .pair_scratch_backing = pair_scratch_backing,
        };

        var started: usize = 0;
        errdefer {
            self.mutex.lock();
            self.stopping = true;
            self.work.broadcast();
            self.mutex.unlock();
            for (self.threads[0..started]) |thread| thread.join();
        }
        for (self.threads, 0..) |*thread, worker_idx| {
            thread.* = try std.Thread.spawn(.{}, workerMain, .{ self, worker_idx });
            started += 1;
        }
    }

    /// Stop and join all persistent workers. The caller must guarantee that
    /// there are no active or queued submissions; `deinit` is not synchronized
    /// with `run`, `runPrepared`, or `parallelFor`.
    pub fn deinit(self: *Executor) void {
        self.mutex.lock();
        self.stopping = true;
        self.work.broadcast();
        self.mutex.unlock();
        for (self.threads) |thread| thread.join();
        if (self.pair_scratch_backing) |backing|
            self.allocator.free(backing);
        if (self.greedy_argmax_candidates.len != 0)
            self.allocator.free(self.greedy_argmax_candidates);
        self.allocator.free(self.threads);
        // Invalidate every plan from this executor epoch before leaving a
        // joined-but-address-stable object behind. Clearing the slice also
        // prevents a stale submission from waiting for workers that no longer
        // exist; reinitialization at the same address receives a fresh epoch.
        self.threads = @constCast((&[_]std.Thread{})[0..]);
        self.greedy_argmax_candidates = @constCast(
            (&[_]GreedyArgmaxCandidate{})[0..],
        );
        self.pair_scratch_backing = null;
        self.pair_scratch_policy = .disabled;
        self.pair_scratch_ledger = derivePairScratchLedger(0, .{}) catch
            unreachable;
        self.instance_id = 0;
        self.current = null;
        self.completed = 0;
    }

    /// Submissions are synchronous but intentionally not caller-concurrent.
    /// A request owns one executor and must externally serialize `run`,
    /// `runPrepared`, and `parallelFor`; this also keeps the hot worker mutex
    /// isolated from an otherwise false-sharing submission lock.
    pub fn run(self: *Executor, projections: []const Projection) TensorError!void {
        try self.acquireSubmission();
        defer self.releaseSubmission();
        if (projections.len == 0) return;
        const total_tiles = try validateAndCountTiles(projections);
        try validatePhaseAliases(projections);
        try validateExecutorStorageAgainstProjections(self, projections);
        const prepared = try self.prepareSharedActivations(projections);
        return self.dispatch(projections, total_tiles, prepared, false);
    }

    /// Execute projections from an already-quantized activation. This lets a
    /// producer fuse its final element-wise operation with Q8 conversion and
    /// avoids materializing a full intermediate f32 tensor.
    pub fn runPrepared(
        self: *Executor,
        projections: []const Projection,
        q_input: []const i8,
        activation_scales: []const f32,
        group_size: u32,
    ) TensorError!void {
        try self.acquireSubmission();
        defer self.releaseSubmission();
        if (projections.len == 0) return;
        // The prepared INT4×Q8 kernels are currently AArch64-only. Falling
        // back through `projection.x` would silently violate this API's
        // explicit-input contract.
        if (comptime builtin.cpu.arch != .aarch64)
            return TensorError.DTypeUnsupported;
        const total_tiles = try validateAndCountTiles(projections);
        try validatePhaseAliases(projections);
        try validatePreparedSliceAliases(projections, q_input, activation_scales);
        try validateExecutorStorageAgainstProjections(self, projections);
        try validateExecutorStorageAgainstSlices(
            self,
            std.mem.sliceAsBytes(q_input),
            std.mem.sliceAsBytes(activation_scales),
        );
        const prepared = try validatePreparedActivations(
            projections,
            q_input,
            activation_scales,
            group_size,
        );
        return self.dispatch(projections, total_tiles, prepared, true);
    }

    /// Execute one typed PairNibble gate/up projection under the persistent
    /// worker epoch. The input is quantized exactly once into executor-owned
    /// scratch, then every dynamic task exclusively owns a coarse range of
    /// complete physical four-row pair tiles. Complete validation and binding
    /// precede scratch/output writes.
    pub fn runPairNibble(
        self: *Executor,
        projection: PairNibbleProjection,
    ) TensorError!void {
        try self.acquireSubmission();
        defer self.releaseSubmission();
        if (comptime builtin.cpu.arch != .aarch64)
            return TensorError.DTypeUnsupported;

        const recipe = try validatePairNibbleProjection(self, projection);
        const selected_pair_tile_rows = try pairNibbleTileRows(
            self.participantCount(),
            projection.weights.group_size,
        );
        const activation_scale_count = int4_matmul.q8ActivationScaleCount(
            projection.in_f,
            projection.weights.group_size,
        );
        const q_input = if (projection.weights.group_size == 8)
            self.shared_q8_g8[0..projection.in_f]
        else
            self.shared_q8_g16[0..projection.in_f];
        const activation_scales = if (projection.weights.group_size == 8)
            self.shared_scales_g8[0..activation_scale_count]
        else
            self.shared_scales_g16[0..activation_scale_count];
        // Binding validates the selected executor scratch against both branch
        // outputs and every persistent PairNibble read before quantization.
        const bound = try recipe.bind(q_input, activation_scales);
        try int4_matmul.quantizeQ8Activation(
            projection.x.asF32(),
            projection.weights.group_size,
            q_input,
            activation_scales,
        );

        const shard_count = projection.out_f / selected_pair_tile_rows +
            @intFromBool(projection.out_f % selected_pair_tile_rows != 0);
        var batch: PairNibbleBatch = .{
            .plan = bound,
            .shard_count = shard_count,
            .tile_rows = selected_pair_tile_rows,
        };
        try self.dispatchWork(.{ .pair_nibble = &batch });
        self.recordPairNibbleSuccess(
            projection.out_f,
            shard_count,
            selected_pair_tile_rows,
        );
    }

    /// Produce the exact prepared-Q8 SwiGLU activation without publishing
    /// full hidden-width gate/up tensors. Validation and input quantization
    /// finish before workers touch caller output; every shard owns disjoint Q8
    /// values/scales. Each participant owns two disjoint executor-arena slices
    /// whose capacity was admitted from the complete model before workers ran.
    pub fn runPairNibbleSiluQ8(
        self: *Executor,
        projection: PairNibbleSiluQ8Projection,
    ) TensorError!void {
        try self.acquireSubmission();
        defer self.releaseSubmission();
        if (comptime builtin.cpu.arch != .aarch64)
            return TensorError.DTypeUnsupported;

        const validated = try validatePairNibbleSiluQ8Projection(
            self,
            projection,
        );
        const selected_pair_tile_rows = try pairNibbleTileRows(
            self.participantCount(),
            projection.weights.group_size,
        );
        const pair_scratch = try self.bindPairScratch(
            selected_pair_tile_rows,
            projection.weights.group_size,
        );
        const input_scale_count = int4_matmul.q8ActivationScaleCount(
            projection.in_f,
            projection.weights.group_size,
        );
        const input_q = if (projection.weights.group_size == 8)
            self.shared_q8_g8[0..projection.in_f]
        else
            self.shared_q8_g16[0..projection.in_f];
        const input_scales = if (projection.weights.group_size == 8)
            self.shared_scales_g8[0..input_scale_count]
        else
            self.shared_scales_g16[0..input_scale_count];
        const bound = try validated.recipe.bind(input_q, input_scales);
        try int4_matmul.quantizeQ8Activation(
            validated.input,
            projection.weights.group_size,
            input_q,
            input_scales,
        );

        const shard_count = projection.out_f / selected_pair_tile_rows +
            @intFromBool(projection.out_f % selected_pair_tile_rows != 0);
        var batch: PairNibbleSiluQ8Batch = .{
            .plan = bound,
            .input = validated.input,
            .input_q = input_q,
            .input_scales = input_scales,
            .q_output = validated.q_output,
            .output_scales = validated.output_scales,
            .down_group_size = validated.down_group_size,
            .participant_count = self.participantCount(),
            .shard_count = shard_count,
            .tile_rows = selected_pair_tile_rows,
            .scratch = pair_scratch.backing,
            .scratch_capacity_rows = pair_scratch.capacity_rows,
            .scratch_participant_stride_rows = pair_scratch.participant_stride_rows,
        };
        try self.dispatchWork(.{ .pair_nibble_silu_q8 = &batch });
        self.recordPairNibbleSuccess(
            projection.out_f,
            shard_count,
            selected_pair_tile_rows,
        );
        atomicSaturatingAdd(&self.pair_silu_q8_runs, 1);
    }

    /// Execute outputless PairNibble -> exact SwiGLU/Q8 -> prepared down under
    /// one persistent-worker epoch. Complete producer and consumer preflight,
    /// binding, and input quantization precede the first caller-owned write.
    /// A release/acquire barrier publishes the complete Q8 activation before
    /// the unchanged down-row kernel begins; this is deliberately not K-split.
    pub fn runPairNibbleSiluQ8Down(
        self: *Executor,
        producer: PairNibbleSiluQ8Projection,
        down: PairNibblePreparedDownProjection,
    ) TensorError!void {
        try self.acquireSubmission();
        defer self.releaseSubmission();
        if (comptime builtin.cpu.arch != .aarch64)
            return TensorError.DTypeUnsupported;

        const validated = try validatePairNibbleSiluQ8Projection(
            self,
            producer,
        );
        const selected_pair_tile_rows = try pairNibbleTileRows(
            self.participantCount(),
            producer.weights.group_size,
        );
        const pair_scratch = try self.bindPairScratch(
            selected_pair_tile_rows,
            producer.weights.group_size,
        );
        if (down.in_f != producer.out_f or
            down.weights.group_size != producer.down_group_size or
            down.weights.packed_layout != .rows4_k16 or
            down.weights.expanded_i8.len != 0)
            return TensorError.ShapeMismatch;
        const down_recipe = try validatePairNibblePreparedDownProjection(
            self,
            down,
            validated.q_output,
            validated.output_scales,
        );
        const producer_reads = [_][]const u8{
            producer.x.data,
            std.mem.sliceAsBytes(producer.x.shape),
            producer.weights.paired_bytes,
            std.mem.sliceAsBytes(producer.weights.scales_f16_pairs),
            std.mem.sliceAsBytes(producer.gate_bias),
            std.mem.sliceAsBytes(producer.up_bias),
        };
        for (producer_reads) |read| {
            if (byteSlicesOverlap(down.out.data, read))
                return TensorError.ShapeMismatch;
        }

        const input_scale_count = int4_matmul.q8ActivationScaleCount(
            producer.in_f,
            producer.weights.group_size,
        );
        const input_q = if (producer.weights.group_size == 8)
            self.shared_q8_g8[0..producer.in_f]
        else
            self.shared_q8_g16[0..producer.in_f];
        const input_scales = if (producer.weights.group_size == 8)
            self.shared_scales_g8[0..input_scale_count]
        else
            self.shared_scales_g16[0..input_scale_count];
        const bound_producer = try validated.recipe.bind(input_q, input_scales);
        const sealed_down: [1]SealedProjection = .{.{
            .plan = try down_recipe.bind(
                validated.q_output,
                validated.output_scales,
            ),
            .tile_count = @intCast(projectionTileCount(down.out_f)),
        }};

        // This is the first executor-private write after caller-owned Pair and
        // down aliases have been preflighted; no caller output is touched yet.
        try int4_matmul.quantizeQ8Activation(
            validated.input,
            producer.weights.group_size,
            input_q,
            input_scales,
        );
        const shard_count = producer.out_f / selected_pair_tile_rows +
            @intFromBool(producer.out_f % selected_pair_tile_rows != 0);
        const participants = self.participantCount();
        var context: PairDownEpochContext = .{
            .producer = .{
                .plan = bound_producer,
                .input = validated.input,
                .input_q = input_q,
                .input_scales = input_scales,
                .q_output = validated.q_output,
                .output_scales = validated.output_scales,
                .down_group_size = validated.down_group_size,
                .participant_count = participants,
                .shard_count = shard_count,
                .tile_rows = selected_pair_tile_rows,
                .scratch = pair_scratch.backing,
                .scratch_capacity_rows = pair_scratch.capacity_rows,
                .scratch_participant_stride_rows = pair_scratch.participant_stride_rows,
            },
            .down = .{
                .sealed_projections = &sealed_down,
                .total_tiles = projectionTileCount(down.out_f),
            },
            .barrier = PhaseBarrier.init(participants),
        };
        try self.parallelForAssumeLease(
            participants,
            @ptrCast(&context),
            PairDownEpochContext.run,
        );
        self.recordPairNibbleSuccess(
            producer.out_f,
            shard_count,
            selected_pair_tile_rows,
        );
        atomicSaturatingAdd(&self.pair_silu_q8_runs, 1);
    }

    /// Snapshot monotonic, saturating successful-work counters. Individual
    /// fields may advance between loads if observed concurrently with a run;
    /// request code should sample before and after its serialized submission.
    pub fn pairNibbleTelemetry(self: *const Executor) PairNibbleTelemetry {
        return .{
            .successful_runs = self.pair_successful_runs.load(.monotonic),
            .activation_quantizations = self.pair_activation_quantizations.load(.monotonic),
            .silu_q8_runs = self.pair_silu_q8_runs.load(.monotonic),
            .m1_runs = self.pair_m1_runs.load(.monotonic),
            .m2_runs = self.pair_m2_runs.load(.monotonic),
            .m3_runs = self.pair_m3_runs.load(.monotonic),
            .m4_runs = self.pair_m4_runs.load(.monotonic),
            .projected_rows = self.pair_projected_rows.load(.monotonic),
            .row_shards = self.pair_row_shards.load(.monotonic),
            .last_tile_rows = self.pair_last_tile_rows.load(.monotonic),
            .last_shard_count = self.pair_last_shard_count.load(.monotonic),
        };
    }

    pub noinline fn pairScratchTelemetry(self: *const Executor) PairScratchTelemetry {
        const successful_dispatches = self.pair_silu_q8_runs.load(.monotonic);
        return .{
            .policy = self.pair_scratch_policy,
            .ledger = self.pair_scratch_ledger,
            .allocations = @intFromBool(self.pair_scratch_backing != null),
            .fixed_dispatches = if (self.pair_scratch_policy == .fixed_256)
                successful_dispatches
            else
                0,
            .model_shaped_dispatches = if (self.pair_scratch_policy == .model_shaped)
                successful_dispatches
            else
                0,
        };
    }

    fn bindPairScratch(
        self: *Executor,
        required_rows: usize,
        producer_group_size: usize,
    ) TensorError!PairScratchView {
        const backing = self.pair_scratch_backing orelse
            return TensorError.ShapeMismatch;
        const ledger = self.pair_scratch_ledger;
        const expected_participant_stride = std.math.mul(
            usize,
            ledger.capacity_rows,
            2,
        ) catch return TensorError.ShapeMismatch;
        const expected_elements = std.math.mul(
            usize,
            ledger.participants,
            expected_participant_stride,
        ) catch return TensorError.ShapeMismatch;
        const expected_bytes = try checkedPairScratchBytes(expected_elements);
        const fixed_elements = std.math.mul(
            usize,
            ledger.participants,
            2 * paired_tile_rows,
        ) catch return TensorError.ShapeMismatch;
        const fixed_bytes = try checkedPairScratchBytes(fixed_elements);
        const admitted_rows = switch (producer_group_size) {
            8 => ledger.selected_g8_rows,
            16 => ledger.selected_g16_rows,
            else => return TensorError.ShapeMismatch,
        };
        if (self.pair_scratch_policy == .disabled or required_rows == 0 or
            admitted_rows != required_rows or
            required_rows > ledger.capacity_rows or
            ledger.participants != self.participantCount() or
            ledger.branch_stride_rows != ledger.capacity_rows or
            ledger.participant_stride_rows != expected_participant_stride or
            ledger.f32_elements != expected_elements or
            ledger.f32_elements != backing.len or
            ledger.bytes != expected_bytes or
            ledger.fixed_counterfactual_bytes != fixed_bytes or
            ledger.reclaimed_bytes != fixed_bytes -| expected_bytes or
            (self.pair_scratch_policy == .fixed_256 and
                ledger.capacity_rows != paired_tile_rows) or
            (self.pair_scratch_policy == .model_shaped and
                ledger.capacity_rows !=
                    @max(ledger.selected_g8_rows, ledger.selected_g16_rows)))
            return TensorError.ShapeMismatch;
        return .{
            .backing = backing,
            .capacity_rows = ledger.capacity_rows,
            .participant_stride_rows = ledger.participant_stride_rows,
        };
    }

    fn recordPairNibbleSuccess(
        self: *Executor,
        projected_rows: usize,
        row_shards: usize,
        selected_pair_tile_rows: usize,
    ) void {
        atomicSaturatingAdd(&self.pair_successful_runs, 1);
        atomicSaturatingAdd(&self.pair_activation_quantizations, 1);
        atomicSaturatingAdd(&self.pair_m1_runs, 1);
        atomicSaturatingAdd(
            &self.pair_projected_rows,
            std.math.cast(u64, projected_rows) orelse std.math.maxInt(u64),
        );
        atomicSaturatingAdd(
            &self.pair_row_shards,
            std.math.cast(u64, row_shards) orelse std.math.maxInt(u64),
        );
        self.pair_last_tile_rows.store(
            std.math.cast(u64, selected_pair_tile_rows) orelse std.math.maxInt(u64),
            .monotonic,
        );
        self.pair_last_shard_count.store(
            std.math.cast(u64, row_shards) orelse std.math.maxInt(u64),
            .monotonic,
        );
    }

    /// Project one compact rows4/K16 vocabulary head and return its exact
    /// greedy winner without allocating or materializing a full logits
    /// vector. The rows4 producer reduces into one private candidate per
    /// participant, and a canonical reduction preserves materialized ties.
    pub fn runGreedyArgmax(
        self: *Executor,
        input: Tensor,
        weights: int4_weights.Int4WeightData,
        out_f: usize,
        in_f: usize,
    ) TensorError!usize {
        try self.acquireSubmission();
        defer self.releaseSubmission();
        if (comptime builtin.cpu.arch != .aarch64)
            return TensorError.DTypeUnsupported;

        const participants = self.participantCount();
        if (self.greedy_argmax_candidates.len != participants)
            return TensorError.ShapeMismatch;

        const geometry = try validateGreedyArgmaxProjection(
            self,
            input,
            weights,
            out_f,
            in_f,
        );
        const source = input.asF32()[0..in_f];
        if (glacier_all_finite_f32_neon(source.ptr, source.len) == 0)
            return TensorError.ShapeMismatch;
        const activation_scale_count = int4_matmul.q8ActivationScaleCount(
            in_f,
            weights.group_size,
        );
        const q_input = if (weights.group_size == 8)
            self.shared_q8_g8[0..in_f]
        else
            self.shared_q8_g16[0..in_f];
        const activation_scales = if (weights.group_size == 8)
            self.shared_scales_g8[0..activation_scale_count]
        else
            self.shared_scales_g16[0..activation_scale_count];
        try int4_matmul.quantizeQ8Activation(
            source,
            weights.group_size,
            q_input,
            activation_scales,
        );

        var context: GreedyArgmaxContext = .{
            .q_input = q_input.ptr,
            .activation_scales = activation_scales.ptr,
            .packed_weights = weights.packed_bytes.ptr,
            .scales = weights.scales_f16_rows4.ptr,
            .candidates = self.greedy_argmax_candidates,
            .out_f = out_f,
            .in_f = in_f,
            .group_size = weights.group_size,
            .tile_count = geometry.tile_count,
            .packed_bytes_per_row = geometry.packed_bytes_per_row,
            .scales_per_row = geometry.scales_per_row,
        };
        try self.parallelForAssumeLease(
            participants,
            @ptrCast(&context),
            GreedyArgmaxContext.run,
        );
        if (context.saw_nan.load(.acquire)) return TensorError.ShapeMismatch;

        var winner: GreedyArgmaxCandidate = .{};
        for (self.greedy_argmax_candidates) |candidate| {
            if (candidate.valid)
                updateGreedyCandidate(&winner, candidate.value, candidate.index);
        }
        if (!winner.valid or winner.index >= out_f)
            return TensorError.ShapeMismatch;
        return winner.index;
    }

    /// Project only caller-certified eligible vocabulary rows. The bitset is
    /// indexed by token ID (LSB first) and is interpreted as a semantic
    /// pre-argmax mask: disallowed rows are `-Inf` and their NaNs are
    /// irrelevant. Empty rows4 tiles never touch weights or execute SDOT.
    /// Malformed/empty masks fail before shared Q8 or candidate scratch writes.
    pub fn runGreedyArgmaxEligible(
        self: *Executor,
        input: Tensor,
        weights: int4_weights.Int4WeightData,
        out_f: usize,
        in_f: usize,
        eligible_words: []const u64,
    ) TensorError!EligibleGreedyResult {
        try self.acquireSubmission();
        defer self.releaseSubmission();
        if (comptime builtin.cpu.arch != .aarch64)
            return TensorError.DTypeUnsupported;

        const participants = self.participantCount();
        if (self.greedy_argmax_candidates.len != participants)
            return TensorError.ShapeMismatch;
        const geometry = try validateGreedyArgmaxProjection(
            self,
            input,
            weights,
            out_f,
            in_f,
        );
        const eligible_rows = try validateEligibleWords(
            self,
            eligible_words,
            out_f,
        );
        const source = input.asF32()[0..in_f];
        if (glacier_all_finite_f32_neon(source.ptr, source.len) == 0)
            return TensorError.ShapeMismatch;

        const activation_scale_count = int4_matmul.q8ActivationScaleCount(
            in_f,
            weights.group_size,
        );
        const q_input = if (weights.group_size == 8)
            self.shared_q8_g8[0..in_f]
        else
            self.shared_q8_g16[0..in_f];
        const activation_scales = if (weights.group_size == 8)
            self.shared_scales_g8[0..activation_scale_count]
        else
            self.shared_scales_g16[0..activation_scale_count];
        try int4_matmul.quantizeQ8Activation(
            source,
            weights.group_size,
            q_input,
            activation_scales,
        );

        var context: EligibleGreedyContext = .{
            .q_input = q_input.ptr,
            .activation_scales = activation_scales.ptr,
            .packed_weights = weights.packed_bytes.ptr,
            .scales = weights.scales_f16_rows4.ptr,
            .eligible_words = eligible_words,
            .candidates = self.greedy_argmax_candidates,
            .out_f = out_f,
            .in_f = in_f,
            .group_size = weights.group_size,
            .tile_count = geometry.tile_count,
            .packed_bytes_per_row = geometry.packed_bytes_per_row,
            .scales_per_row = geometry.scales_per_row,
        };
        try self.parallelForAssumeLease(
            participants,
            @ptrCast(&context),
            EligibleGreedyContext.run,
        );
        if (context.saw_nan.load(.acquire))
            return TensorError.ShapeMismatch;

        var winner: GreedyArgmaxCandidate = .{};
        for (self.greedy_argmax_candidates) |candidate| {
            if (candidate.valid)
                updateGreedyCandidate(&winner, candidate.value, candidate.index);
        }
        if (!winner.valid or winner.index >= out_f)
            return TensorError.ShapeMismatch;
        const producer_rows = context.producer_rows.load(.monotonic);
        const producer_runs = context.producer_runs.load(.monotonic);
        const minimum_producer_runs = producer_rows / greedy_argmax_tile_rows +
            @intFromBool(producer_rows % greedy_argmax_tile_rows != 0);
        const max_producer_rows = std.math.mul(
            usize,
            eligible_rows,
            4,
        ) catch std.math.maxInt(usize);
        if (producer_rows < eligible_rows or producer_rows > out_f or
            producer_rows > max_producer_rows or producer_rows % 4 != 0 or
            producer_runs < minimum_producer_runs or
            producer_runs > producer_rows / 4)
            return TensorError.ShapeMismatch;
        const tile_scratch_bytes = std.math.mul(
            usize,
            participants,
            greedy_argmax_tile_rows * @sizeOf(f32),
        ) catch return TensorError.ShapeMismatch;
        return .{
            .token_index = winner.index,
            .eligible_rows = eligible_rows,
            .producer_rows = producer_rows,
            .skipped_rows = out_f - producer_rows,
            .overcomputed_rows = producer_rows - eligible_rows,
            .producer_runs = producer_runs,
            .tile_scratch_bytes = tile_scratch_bytes,
        };
    }

    pub fn greedyArgmaxScratchBytes(self: *const Executor) usize {
        if (self.greedy_argmax_candidates.len == 0) return 0;
        return greedyArgmaxScratchBytesForParticipants(
            self.greedy_argmax_candidates.len,
        ) catch unreachable;
    }

    /// Execute a fixed task domain on the caller and persistent workers
    /// without allocating or spawning threads. The call is synchronous, so
    /// stack-backed context is valid and all workers are joined before return.
    /// A callback must not recursively submit work to this same executor.
    pub fn parallelFor(
        self: *Executor,
        task_count: usize,
        context: *anyopaque,
        task: ParallelForFn,
    ) TensorError!void {
        try self.acquireSubmission();
        defer self.releaseSubmission();
        return self.parallelForAssumeLease(task_count, context, task);
    }

    fn parallelForAssumeLease(
        self: *Executor,
        task_count: usize,
        context: *anyopaque,
        task: ParallelForFn,
    ) TensorError!void {
        if (task_count == 0) return;
        try validateParallelTaskCount(task_count, self.participantCount());

        var batch: ParallelForBatch = .{
            .context = context,
            .task = task,
            .task_count = task_count,
        };
        return self.dispatchWork(.{ .parallel_for = &batch });
    }

    /// Execute Q/K/V, coordinator RoPE/KV, disjoint attention, WO,
    /// residual/RMSNorm, gate/up, a prepared-activation bridge and down
    /// projection with one worker broadcast. Participants rendezvous inside the
    /// callback instead of returning to executor condition variables between
    /// phases. Validation and the first Q8 preparation happen before output is
    /// touched.
    pub fn runHandoffGraph(self: *Executor, graph: HandoffGraph) TensorError!void {
        try self.acquireSubmission();
        defer self.releaseSubmission();
        const participants = self.participantCount();
        const validated = try validateHandoffGraph(self, graph);

        const qkv_prepared = try self.prepareSharedActivations(graph.qkv);

        var context: HandoffGraphContext = .{
            .executor = self,
            .qkv = .{
                .projections = graph.qkv,
                .total_tiles = validated.qkv_tiles,
                .prepared_g8 = qkv_prepared.g8,
                .prepared_g16 = qkv_prepared.g16,
            },
            .bridge_context = graph.bridge_context,
            .bridge = graph.bridge,
            .attention = .{
                .context = graph.attention_context,
                .task = graph.attention_task,
                .task_count = graph.attention_task_count,
            },
            .output = .{
                .projections = graph.output,
                .total_tiles = validated.output_tiles,
            },
            .mlp_bridge_context = graph.mlp_bridge_context,
            .mlp_bridge = graph.mlp_bridge,
            .mlp = .{
                .projections = graph.mlp,
                .total_tiles = validated.mlp_tiles,
            },
            .paired_mlp_plan = validated.paired_mlp_plan,
            .serial_final_bridge = validated.serial_final_bridge,
            .parallel_final_bridge = validated.parallel_final_bridge,
            .final = .{
                .projections = graph.final.projections,
                .total_tiles = validated.final_tiles,
                .prepared_g8 = validated.final_prepared.g8,
                .prepared_g16 = validated.final_prepared.g16,
                .force_prepared = true,
            },
            .barrier = PhaseBarrier.init(participants),
        };

        // Every participant claims one outer task and immediately reaches the
        // first barrier, so no participant can consume a second task. This is
        // one executor dispatch even though the callback contains five phases.
        return self.parallelForAssumeLease(
            participants,
            @ptrCast(&context),
            HandoffGraphContext.run,
        );
    }

    /// Validate and normalize one production layer graph into immutable,
    /// shape-pointer-free recipes. The first call pays the complete checked
    /// preflight; subsequent tokens use `runSealedHandoffGraph`.
    pub fn prepareSealedHandoffPlan(
        self: *Executor,
        layer_index: usize,
        graph: HandoffGraph,
    ) TensorError!SealedHandoffPlan {
        try self.acquireSubmission();
        defer self.releaseSubmission();
        if (graph.qkv.len != 3 or graph.output.len != 1 or graph.mlp.len != 2 or
            graph.final.projections.len != 1)
            return TensorError.ShapeMismatch;
        const binding = graph.sealed_binding orelse
            return TensorError.ShapeMismatch;
        const validated = try validateHandoffGraph(self, graph);
        const paired_mlp_plan = validated.paired_mlp_plan orelse
            return TensorError.ShapeMismatch;

        const qkv_sources = try prepareSealedSources(self, graph.qkv);
        const output_sources = try prepareSealedSources(self, graph.output);
        const mlp_sources = try prepareSealedSources(self, graph.mlp);
        const binding_key = try binding(
            graph.bridge_context,
            graph.attention_context,
            graph.mlp_bridge_context,
            layer_index,
            graph.sealed_position,
            graph.attention_task_count,
        );
        var qkv: [3]SealedProjection = undefined;
        var output: [1]SealedProjection = undefined;
        var mlp: [2]SealedProjection = undefined;
        var final: [1]SealedProjection = undefined;
        for (graph.qkv, 0..) |projection, index|
            qkv[index] = try sealProjection(projection, qkv_sources);
        for (graph.output, 0..) |projection, index|
            output[index] = try sealProjection(projection, output_sources);
        for (graph.mlp, 0..) |projection, index|
            mlp[index] = try sealProjection(projection, mlp_sources);

        const final_projection = graph.final.projections[0];
        const final_recipe = try int4_matmul.PreparedQ8MatvecPlan.init(
            final_projection.weights,
            final_projection.bias,
            final_projection.out,
            final_projection.out_f,
            final_projection.in_f,
        );
        final[0] = .{
            .plan = try final_recipe.bind(
                graph.final.q_input,
                graph.final.activation_scales,
            ),
            .tile_count = @intCast(projectionTileCount(final_projection.out_f)),
        };

        var plan: SealedHandoffPlan = .{
            .abi = sealed_handoff_abi,
            .integrity = 0,
            .storage_address = 0,
            .admission_token = 0,
            .executor_address = @intFromPtr(self),
            .executor_instance = self.instance_id,
            .participants = self.participantCount(),
            .layer_index = layer_index,
            .qkv = qkv,
            .qkv_tiles = validated.qkv_tiles,
            .qkv_sources = qkv_sources,
            .bridge = graph.bridge,
            .attention_task = graph.attention_task,
            .attention_task_count = graph.attention_task_count,
            .binding = binding,
            .binding_key = binding_key,
            .output = output,
            .output_tiles = validated.output_tiles,
            .output_sources = output_sources,
            .mlp_bridge = graph.mlp_bridge,
            .mlp = mlp,
            .mlp_tiles = validated.mlp_tiles,
            .mlp_sources = mlp_sources,
            .paired_mlp_plan = paired_mlp_plan,
            .final = final,
            .final_tiles = validated.final_tiles,
        };
        plan.integrity = sealedPlanIntegrity(&plan);
        return plan;
    }

    /// Finish a plan after it has been moved into its final request-local
    /// storage. Descriptor integrity and self-aliasing are checked here; the
    /// decode path rechecks descriptor integrity before every dispatch so a
    /// post-finalization mutation fails closed.
    pub fn finalizeSealedHandoffPlan(
        self: *Executor,
        plan: *SealedHandoffPlan,
    ) TensorError!void {
        try self.acquireSubmission();
        defer self.releaseSubmission();
        if (plan.abi != sealed_handoff_abi or
            plan.integrity != sealedPlanIntegrity(plan) or
            plan.storage_address != 0 or plan.admission_token != 0 or
            plan.executor_address != @intFromPtr(self) or
            plan.executor_instance != self.instance_id or
            plan.participants != self.participantCount())
            return TensorError.ShapeMismatch;
        try validateSealedPlanStorage(self, plan);
        plan.storage_address = @intFromPtr(plan);
        plan.admission_token = sealedAdmissionToken(plan);
    }

    /// Run a finalized sealed layer plan. The fixed-size descriptor integrity,
    /// storage identity, ABI, executor epoch, participant topology, layer
    /// identity, and dynamic callback bindings are checked before Q8
    /// preparation or output writes.
    pub fn runSealedHandoffGraph(
        self: *Executor,
        plan: *const SealedHandoffPlan,
        invocation: SealedHandoffInvocation,
    ) TensorError!void {
        try self.acquireSubmission();
        defer self.releaseSubmission();
        const participants = self.participantCount();
        if (plan.abi != sealed_handoff_abi or
            plan.integrity != sealedPlanIntegrity(plan) or
            plan.storage_address != @intFromPtr(plan) or
            plan.admission_token != sealedAdmissionToken(plan) or
            plan.executor_address != @intFromPtr(self) or
            plan.executor_instance != self.instance_id or
            plan.participants != participants or
            plan.layer_index != invocation.layer_index or
            plan.attention_task_count != invocation.attention_task_count or
            invocation.attention_task_count == 0)
            return TensorError.ShapeMismatch;
        try validateParallelTaskCount(invocation.attention_task_count, participants);
        const binding_key = try plan.binding(
            invocation.bridge_context,
            invocation.attention_context,
            invocation.mlp_bridge_context,
            invocation.layer_index,
            invocation.position,
            invocation.attention_task_count,
        );
        if (binding_key != plan.binding_key) return TensorError.ShapeMismatch;

        // This is real per-token work, not cached data: only the source
        // selection and target bindings were sealed.
        try quantizeSealedSources(plan.qkv_sources);
        var context: HandoffGraphContext = .{
            .executor = self,
            .qkv = .{
                .sealed_projections = plan.qkv[0..],
                .sealed_sources = plan.qkv_sources,
                .total_tiles = plan.qkv_tiles,
            },
            .bridge_context = invocation.bridge_context,
            .bridge = plan.bridge,
            .attention = .{
                .context = invocation.attention_context,
                .task = plan.attention_task,
                .task_count = invocation.attention_task_count,
            },
            .output = .{
                .sealed_projections = plan.output[0..],
                .sealed_sources = plan.output_sources,
                .total_tiles = plan.output_tiles,
            },
            .mlp_bridge_context = invocation.mlp_bridge_context,
            .mlp_bridge = plan.mlp_bridge,
            .mlp = .{
                .sealed_projections = plan.mlp[0..],
                .sealed_sources = plan.mlp_sources,
                .total_tiles = plan.mlp_tiles,
            },
            .paired_mlp_plan = plan.paired_mlp_plan,
            .serial_final_bridge = null,
            .parallel_final_bridge = null,
            .final = .{
                .sealed_projections = plan.final[0..],
                .total_tiles = plan.final_tiles,
            },
            .barrier = PhaseBarrier.init(participants),
        };

        return self.parallelForAssumeLease(
            participants,
            @ptrCast(&context),
            HandoffGraphContext.run,
        );
    }

    /// Number of participants available to a synchronous dispatch, including
    /// the submitting thread.
    pub fn participantCount(self: *const Executor) usize {
        return self.threads.len + 1;
    }

    fn acquireSubmission(self: *Executor) TensorError!void {
        if (self.submission_lease.swap(true, .acquire))
            return TensorError.ExecutorBusy;
    }

    fn releaseSubmission(self: *Executor) void {
        self.submission_lease.store(false, .release);
    }

    fn dispatch(
        self: *Executor,
        projections: []const Projection,
        total_tiles: usize,
        prepared: PreparedSet,
        force_prepared: bool,
    ) TensorError!void {
        var batch = Batch{
            .projections = projections,
            .total_tiles = total_tiles,
            .prepared_g8 = prepared.g8,
            .prepared_g16 = prepared.g16,
            .force_prepared = force_prepared,
        };
        return self.dispatchWork(.{ .projections = &batch });
    }

    fn dispatchWork(self: *Executor, item: WorkItem) TensorError!void {
        if (self.threads.len == 0) return runWorkItem(item);

        self.mutex.lock();
        std.debug.assert(self.current == null);
        self.current = item;
        self.completed = 0;
        self.generation +%= 1;
        self.work.broadcast();
        self.mutex.unlock();

        runWorkItem(item) catch |err| {
            self.mutex.lock();
            setWorkError(item, err);
            self.mutex.unlock();
        };

        self.mutex.lock();
        while (self.completed != self.threads.len) self.done.wait(&self.mutex);
        self.current = null;
        const err = workError(item);
        self.mutex.unlock();
        if (err) |value| return value;
    }

    fn prepareSharedActivations(
        self: *Executor,
        projections: []const Projection,
    ) TensorError!PreparedSet {
        // Shared prepared activations feed the AArch64 prequantized kernels.
        // Other targets must leave the set empty so runProjectionRange selects
        // the portable packed-INT4 path instead of failing during preflight.
        if (comptime builtin.cpu.arch != .aarch64) return .{};

        var source_g8: ?Projection = null;
        var source_g16: ?Projection = null;
        var share_g8 = true;
        var share_g16 = true;
        for (projections) |projection| {
            if (!projection.use_q8 or
                projection.weights.expanded_i8.len >= projection.weights.num_elements or
                projection.in_f > max_shared_input)
                continue;
            const slot = if (projection.weights.group_size == 8)
                &source_g8
            else if (projection.weights.group_size == 16)
                &source_g16
            else
                continue;
            if (slot.*) |existing| {
                if (existing.x.asF32().ptr != projection.x.asF32().ptr or
                    existing.in_f != projection.in_f)
                {
                    if (projection.weights.group_size == 8)
                        share_g8 = false
                    else
                        share_g16 = false;
                }
            } else {
                slot.* = projection;
            }
        }

        var prepared: PreparedSet = .{};
        if (source_g8) |projection| {
            if (share_g8) {
                const scale_count = int4_matmul.q8ActivationScaleCount(projection.in_f, 8);
                try int4_matmul.quantizeQ8Activation(
                    projection.x.asF32(),
                    8,
                    self.shared_q8_g8[0..projection.in_f],
                    self.shared_scales_g8[0..scale_count],
                );
                prepared.g8 = .{
                    .q_input = self.shared_q8_g8[0..projection.in_f],
                    .scales = self.shared_scales_g8[0..scale_count],
                };
            }
        }
        if (source_g16) |projection| {
            if (share_g16) {
                const scale_count = int4_matmul.q8ActivationScaleCount(projection.in_f, 16);
                try int4_matmul.quantizeQ8Activation(
                    projection.x.asF32(),
                    16,
                    self.shared_q8_g16[0..projection.in_f],
                    self.shared_scales_g16[0..scale_count],
                );
                prepared.g16 = .{
                    .q_input = self.shared_q8_g16[0..projection.in_f],
                    .scales = self.shared_scales_g16[0..scale_count],
                };
            }
        }
        return prepared;
    }

    fn workerMain(self: *Executor, worker_idx: usize) void {
        var seen_generation: usize = 0;
        while (true) {
            self.mutex.lock();
            while (self.generation == seen_generation and !self.stopping)
                self.work.wait(&self.mutex);
            if (self.stopping) {
                self.mutex.unlock();
                return;
            }
            const generation = self.generation;
            const item = self.current.?;
            self.mutex.unlock();

            _ = worker_idx;
            runWorkItem(item) catch |err| {
                self.mutex.lock();
                setWorkError(item, err);
                self.mutex.unlock();
            };

            self.mutex.lock();
            seen_generation = generation;
            self.completed += 1;
            if (self.completed == self.threads.len) self.done.signal();
            self.mutex.unlock();
        }
    }
};

fn runWorkItem(item: WorkItem) TensorError!void {
    return switch (item) {
        .projections => |batch| runBatchWorker(batch),
        .pair_nibble => |batch| runPairNibbleBatchWorker(batch),
        .pair_nibble_silu_q8 => |batch| runPairNibbleSiluQ8BatchWorker(batch),
        .parallel_for => |batch| runParallelForWorker(batch),
    };
}

fn setWorkError(item: WorkItem, err: TensorError) void {
    switch (item) {
        inline else => |batch| if (batch.err == null) {
            batch.err = err;
        },
    }
}

fn workError(item: WorkItem) ?TensorError {
    return switch (item) {
        inline else => |batch| batch.err,
    };
}

fn runParallelForWorker(batch: *ParallelForBatch) TensorError!void {
    while (true) {
        const task_index = batch.next_task.fetchAdd(1, .monotonic);
        if (task_index >= batch.task_count) return;
        try batch.task(batch.context, task_index);
    }
}

fn runPairNibbleBatchWorker(batch: *PairNibbleBatch) TensorError!void {
    if (batch.tile_rows == 0 or batch.tile_rows % 4 != 0)
        return TensorError.ShapeMismatch;
    while (true) {
        const shard_index = batch.next_shard.fetchAdd(1, .monotonic);
        if (shard_index >= batch.shard_count) return;
        if (comptime builtin.is_test) {
            if (batch.test_shard_visits) |visits| {
                if (shard_index >= visits.len or
                    visits[shard_index].fetchAdd(1, .monotonic) != 0)
                    return TensorError.ShapeMismatch;
            }
        }
        const row_start = std.math.mul(
            usize,
            shard_index,
            batch.tile_rows,
        ) catch
            return TensorError.ShapeMismatch;
        const row_end = @min(
            std.math.add(
                usize,
                row_start,
                batch.tile_rows,
            ) catch batch.plan.recipe.out_f,
            batch.plan.recipe.out_f,
        );
        try batch.plan.runRows(row_start, row_end);
    }
}

fn runPairNibbleSiluQ8BatchWorker(
    batch: *PairNibbleSiluQ8Batch,
) TensorError!void {
    // `WorkItem` keeps every worker variant reachable in test binaries even
    // when PairNibble admission is impossible on the target. Cut the NEON-only
    // tile body at comptime so non-AArch64 test links do not retain an
    // unavailable C symbol, while a direct misuse still fails closed.
    if (comptime builtin.cpu.arch != .aarch64)
        return TensorError.DTypeUnsupported;
    const activation_group_size: usize = switch (batch.down_group_size) {
        8 => 32,
        16 => 16,
        else => return TensorError.ShapeMismatch,
    };
    if (batch.tile_rows == 0 or batch.tile_rows > paired_tile_rows or
        batch.tile_rows % activation_group_size != 0)
        return TensorError.ShapeMismatch;
    const expected_scratch_stride = std.math.mul(
        usize,
        batch.scratch_capacity_rows,
        2,
    ) catch return TensorError.ShapeMismatch;
    if (batch.participant_count == 0 or
        batch.tile_rows > batch.scratch_capacity_rows or
        batch.scratch_participant_stride_rows !=
            expected_scratch_stride)
        return TensorError.ShapeMismatch;
    const participant_index = batch.next_participant.fetchAdd(1, .monotonic);
    if (participant_index >= batch.participant_count)
        return TensorError.ShapeMismatch;
    const scratch_start = std.math.mul(
        usize,
        participant_index,
        batch.scratch_participant_stride_rows,
    ) catch return TensorError.ShapeMismatch;
    const gate_end = std.math.add(
        usize,
        scratch_start,
        batch.scratch_capacity_rows,
    ) catch return TensorError.ShapeMismatch;
    const up_end = std.math.add(
        usize,
        gate_end,
        batch.scratch_capacity_rows,
    ) catch return TensorError.ShapeMismatch;
    if (up_end > batch.scratch.len) return TensorError.ShapeMismatch;
    const gate_tile = batch.scratch[scratch_start..gate_end];
    const up_tile = batch.scratch[gate_end..up_end];
    // Static contiguous stripes keep nearly all Q8 and scale writes private to
    // one core. Dynamic 64-row claims made four participants repeatedly write
    // adjacent scale entries in the same cache line on Apple silicon.
    const shards_per_participant = batch.shard_count / batch.participant_count;
    const remainder = batch.shard_count % batch.participant_count;
    const shard_start = participant_index * shards_per_participant +
        @min(participant_index, remainder);
    const shard_end = shard_start + shards_per_participant +
        @intFromBool(participant_index < remainder);
    for (shard_start..shard_end) |shard_index| {
        if (comptime builtin.is_test) {
            if (batch.test_shard_visits) |visits| {
                if (shard_index >= visits.len or
                    visits[shard_index].fetchAdd(1, .monotonic) != 0)
                    return TensorError.ShapeMismatch;
            }
        }
        const row_start = std.math.mul(
            usize,
            shard_index,
            batch.tile_rows,
        ) catch return TensorError.ShapeMismatch;
        const row_end = @min(
            std.math.add(usize, row_start, batch.tile_rows) catch
                batch.plan.recipe.out_f,
            batch.plan.recipe.out_f,
        );
        if (row_start >= row_end or row_start % activation_group_size != 0)
            return TensorError.ShapeMismatch;
        const row_count = row_end - row_start;
        batch.plan.runRowsIntoPrevalidated(
            row_start,
            row_end,
            gate_tile[0..row_count],
            up_tile[0..row_count],
        );
        const scale_start = row_start / activation_group_size;
        const scale_count = row_count / activation_group_size +
            @intFromBool(row_count % activation_group_size != 0);
        const scale_end = std.math.add(
            usize,
            scale_start,
            scale_count,
        ) catch return TensorError.ShapeMismatch;
        if (row_end > batch.q_output.len or scale_end > batch.output_scales.len)
            return TensorError.ShapeMismatch;
        kernels.siluMulQuantizeQ8SlicesPrevalidated(
            gate_tile[0..row_count],
            up_tile[0..row_count],
            activation_group_size,
            batch.q_output[row_start..row_end],
            batch.output_scales[scale_start..scale_end],
        );
    }
}

/// When a graph has exactly one task per participant, one atomic claim is
/// sufficient: successful executions cannot leave a task unclaimed, so the
/// usual second out-of-range claim only adds contention. Other task geometries
/// retain the general dynamic queue.
fn runGraphParallelWorker(
    batch: *ParallelForBatch,
    participants: usize,
) TensorError!void {
    if (batch.task_count == participants) {
        const task_index = batch.next_task.fetchAdd(1, .monotonic);
        if (task_index >= batch.task_count) return TensorError.ShapeMismatch;
        return batch.task(batch.context, task_index);
    }
    return runParallelForWorker(batch);
}

fn validateHandoffGraph(
    executor: *Executor,
    graph: HandoffGraph,
) TensorError!ValidatedHandoffGraph {
    // The mandatory final phase consumes an explicit prepared Q8 input. Keep
    // the contract fail-closed until that kernel is portable.
    if (comptime builtin.cpu.arch != .aarch64)
        return TensorError.DTypeUnsupported;
    if (graph.qkv.len == 0 or graph.output.len == 0 or graph.mlp.len == 0 or
        graph.final.projections.len == 0 or graph.attention_task_count == 0)
        return TensorError.ShapeMismatch;

    const participants = executor.participantCount();
    try validateParallelTaskCount(graph.attention_task_count, participants);
    const qkv_tiles = try validateAndCountTiles(graph.qkv);
    const output_tiles = try validateAndCountTiles(graph.output);
    var mlp_tiles = try validateAndCountTiles(graph.mlp);
    const final_tiles = try validateAndCountTiles(graph.final.projections);
    try validatePhaseAliases(graph.qkv);
    try validatePhaseAliases(graph.output);
    try validatePhaseAliases(graph.mlp);
    try validatePhaseAliases(graph.final.projections);
    try validateGraphPersistentAliases(graph);
    try validateExecutorStorageAgainstProjections(executor, graph.qkv);
    try validateExecutorStorageAgainstProjections(executor, graph.output);
    try validateExecutorStorageAgainstProjections(executor, graph.mlp);
    try validateExecutorStorageAgainstProjections(executor, graph.final.projections);
    try validateExecutorStorageAgainstSlices(
        executor,
        std.mem.sliceAsBytes(graph.final.q_input),
        std.mem.sliceAsBytes(graph.final.activation_scales),
    );
    try validatePreparedAliases(graph.final);
    const final_prepared = try validatePreparedActivations(
        graph.final.projections,
        graph.final.q_input,
        graph.final.activation_scales,
        graph.final.group_size,
    );

    var serial_final_bridge: ?SerialBridge = null;
    var parallel_final_bridge: ?ParallelForBatch = null;
    var paired_mlp_plan: ?kernels.SiluMulQuantizeQ8Plan = null;
    switch (graph.final_handoff) {
        .serial => |bridge| serial_final_bridge = bridge,
        .parallel => |bridge| {
            if (bridge.task_count == 0) return TensorError.ShapeMismatch;
            try validateParallelTaskCount(bridge.task_count, participants);
            parallel_final_bridge = .{
                .context = bridge.context,
                .task = bridge.task,
                .task_count = bridge.task_count,
            };
        },
        .paired_silu_q8 => |bridge| {
            mlp_tiles = try validatePairedProjectionTiles(graph.mlp);
            const plan = try validatePairedSiluQ8Bridge(graph, bridge);
            try validatePairedExecutorScratchAliases(executor, plan);
            paired_mlp_plan = plan;
        },
    }
    return .{
        .qkv_tiles = qkv_tiles,
        .output_tiles = output_tiles,
        .mlp_tiles = mlp_tiles,
        .final_tiles = final_tiles,
        .final_prepared = final_prepared,
        .serial_final_bridge = serial_final_bridge,
        .parallel_final_bridge = parallel_final_bridge,
        .paired_mlp_plan = paired_mlp_plan,
    };
}

fn projectionTileCount(out_f: usize) usize {
    return out_f / tile_rows + @intFromBool(out_f % tile_rows != 0);
}

fn sourceForGroup(
    sources: SealedPreparedSet,
    group_size: usize,
) ?SealedActivationSource {
    return if (group_size == 8)
        sources.g8
    else if (group_size == 16)
        sources.g16
    else
        null;
}

inline fn sealMix(state: u64, value: u64) u64 {
    return (state ^ value) *% 0x0000_0100_0000_01b3;
}

inline fn pointerBits(pointer: anytype) u64 {
    return @intCast(@intFromPtr(pointer));
}

fn mixSealedSource(state: u64, maybe_source: ?SealedActivationSource) u64 {
    var hash = state;
    const source = maybe_source orelse return sealMix(hash, 0);
    hash = sealMix(hash, 1);
    hash = sealMix(hash, pointerBits(source.input));
    hash = sealMix(hash, pointerBits(source.q_output));
    hash = sealMix(hash, pointerBits(source.activation_scales));
    hash = sealMix(hash, source.input_len);
    hash = sealMix(hash, source.scale_count);
    return sealMix(hash, source.group_size);
}

fn mixSealedProjection(state: u64, projection: SealedProjection) u64 {
    var hash = state;
    const bound = projection.plan;
    const recipe = bound.recipe;
    hash = sealMix(hash, pointerBits(recipe.packed_weights));
    hash = sealMix(hash, pointerBits(recipe.scales));
    hash = sealMix(hash, if (recipe.bias) |bias| pointerBits(bias) else 0);
    hash = sealMix(hash, pointerBits(recipe.output));
    hash = sealMix(hash, recipe.out_f);
    hash = sealMix(hash, recipe.in_f);
    hash = sealMix(hash, recipe.group_size);
    hash = sealMix(hash, recipe.packed_bytes_per_row);
    hash = sealMix(hash, recipe.scales_per_row);
    hash = sealMix(hash, pointerBits(bound.q_input));
    hash = sealMix(hash, pointerBits(bound.activation_scales));
    return sealMix(hash, projection.tile_count);
}

fn sealedPlanIntegrity(plan: *const SealedHandoffPlan) u64 {
    var hash: u64 = 0xcbf2_9ce4_8422_2325;
    hash = sealMix(hash, plan.abi);
    hash = sealMix(hash, plan.executor_address);
    hash = sealMix(hash, plan.executor_instance);
    hash = sealMix(hash, plan.participants);
    hash = sealMix(hash, plan.layer_index);
    for (plan.qkv) |projection| hash = mixSealedProjection(hash, projection);
    hash = sealMix(hash, plan.qkv_tiles);
    hash = mixSealedSource(hash, plan.qkv_sources.g8);
    hash = mixSealedSource(hash, plan.qkv_sources.g16);
    hash = sealMix(hash, pointerBits(plan.bridge));
    hash = sealMix(hash, pointerBits(plan.attention_task));
    hash = sealMix(hash, plan.attention_task_count);
    hash = sealMix(hash, pointerBits(plan.binding));
    hash = sealMix(hash, plan.binding_key);
    for (plan.output) |projection| hash = mixSealedProjection(hash, projection);
    hash = sealMix(hash, plan.output_tiles);
    hash = mixSealedSource(hash, plan.output_sources.g8);
    hash = mixSealedSource(hash, plan.output_sources.g16);
    hash = sealMix(hash, pointerBits(plan.mlp_bridge));
    for (plan.mlp) |projection| hash = mixSealedProjection(hash, projection);
    hash = sealMix(hash, plan.mlp_tiles);
    hash = mixSealedSource(hash, plan.mlp_sources.g8);
    hash = mixSealedSource(hash, plan.mlp_sources.g16);
    const paired = plan.paired_mlp_plan;
    hash = sealMix(hash, pointerBits(paired.gate.ptr));
    hash = sealMix(hash, paired.gate.len);
    hash = sealMix(hash, pointerBits(paired.up.ptr));
    hash = sealMix(hash, paired.up.len);
    hash = sealMix(hash, pointerBits(paired.q_output.ptr));
    hash = sealMix(hash, paired.q_output.len);
    hash = sealMix(hash, pointerBits(paired.activation_scales.ptr));
    hash = sealMix(hash, paired.activation_scales.len);
    hash = sealMix(hash, paired.activation_group_size);
    hash = sealMix(hash, paired.group_count);
    for (plan.final) |projection| hash = mixSealedProjection(hash, projection);
    return sealMix(hash, plan.final_tiles);
}

inline fn sealedAdmissionToken(plan: *const SealedHandoffPlan) u64 {
    var token: u64 = 0x9e37_79b9_7f4a_7c15;
    token = sealMix(token, plan.abi);
    token = sealMix(token, plan.integrity);
    token = sealMix(token, plan.storage_address);
    token = sealMix(token, plan.executor_address);
    token = sealMix(token, plan.executor_instance);
    return sealMix(token, plan.participants);
}

fn planStorageOverlapsProjection(
    storage: []const u8,
    projection: SealedProjection,
) TensorError!bool {
    const bound = projection.plan;
    const recipe = bound.recipe;
    const out_f: usize = recipe.out_f;
    const in_f: usize = recipe.in_f;
    const packed_count = std.math.mul(
        usize,
        out_f,
        recipe.packed_bytes_per_row,
    ) catch return TensorError.ShapeMismatch;
    const scale_count = std.math.mul(
        usize,
        out_f,
        recipe.scales_per_row,
    ) catch return TensorError.ShapeMismatch;
    const activation_scale_count = int4_matmul.q8ActivationScaleCount(
        in_f,
        recipe.group_size,
    );
    if (byteSlicesOverlap(storage, recipe.packed_weights[0..packed_count]) or
        byteSlicesOverlap(storage, std.mem.sliceAsBytes(recipe.scales[0..scale_count])) or
        byteSlicesOverlap(storage, std.mem.sliceAsBytes(recipe.output[0..out_f])) or
        byteSlicesOverlap(storage, std.mem.sliceAsBytes(bound.q_input[0..in_f])) or
        byteSlicesOverlap(
            storage,
            std.mem.sliceAsBytes(bound.activation_scales[0..activation_scale_count]),
        ))
        return true;
    if (recipe.bias) |bias| {
        if (byteSlicesOverlap(storage, std.mem.sliceAsBytes(bias[0..out_f])))
            return true;
    }
    return false;
}

fn planStorageOverlapsSource(
    storage: []const u8,
    maybe_source: ?SealedActivationSource,
) bool {
    const source = maybe_source orelse return false;
    return byteSlicesOverlap(
        storage,
        std.mem.sliceAsBytes(source.input[0..source.input_len]),
    ) or byteSlicesOverlap(
        storage,
        std.mem.sliceAsBytes(source.q_output[0..source.input_len]),
    ) or byteSlicesOverlap(
        storage,
        std.mem.sliceAsBytes(source.activation_scales[0..source.scale_count]),
    );
}

fn validateSealedPlanStorage(
    executor: *const Executor,
    plan: *const SealedHandoffPlan,
) TensorError!void {
    const storage = std.mem.asBytes(plan);
    for (executorStorage(executor)) |executor_bytes| {
        if (byteSlicesOverlap(storage, executor_bytes))
            return TensorError.ShapeMismatch;
    }
    const phases = .{ plan.qkv[0..], plan.output[0..], plan.mlp[0..], plan.final[0..] };
    inline for (phases) |phase| {
        for (phase) |projection| {
            if (try planStorageOverlapsProjection(storage, projection))
                return TensorError.ShapeMismatch;
        }
    }
    const sources = .{
        plan.qkv_sources.g8,
        plan.qkv_sources.g16,
        plan.output_sources.g8,
        plan.output_sources.g16,
        plan.mlp_sources.g8,
        plan.mlp_sources.g16,
    };
    inline for (sources) |source| {
        if (planStorageOverlapsSource(storage, source))
            return TensorError.ShapeMismatch;
    }
    const paired = plan.paired_mlp_plan;
    if (byteSlicesOverlap(storage, std.mem.sliceAsBytes(paired.gate)) or
        byteSlicesOverlap(storage, std.mem.sliceAsBytes(paired.up)) or
        byteSlicesOverlap(storage, std.mem.sliceAsBytes(paired.q_output)) or
        byteSlicesOverlap(storage, std.mem.sliceAsBytes(paired.activation_scales)))
        return TensorError.ShapeMismatch;
}

fn prepareSealedSources(
    executor: *Executor,
    projections: []const Projection,
) TensorError!SealedPreparedSet {
    var sources: SealedPreparedSet = .{};
    for (projections) |projection| {
        if (!projection.use_q8 or projection.in_f > max_shared_input or
            projection.weights.expanded_i8.len >= projection.weights.num_elements or
            (projection.weights.group_size != 8 and
                projection.weights.group_size != 16))
            return TensorError.ShapeMismatch;
        const input = projection.x.asF32()[0..projection.in_f];
        const scale_count = int4_matmul.q8ActivationScaleCount(
            projection.in_f,
            projection.weights.group_size,
        );
        const candidate: SealedActivationSource = if (projection.weights.group_size == 8)
            .{
                .input = input.ptr,
                .q_output = executor.shared_q8_g8[0..projection.in_f].ptr,
                .activation_scales = executor.shared_scales_g8[0..scale_count].ptr,
                .input_len = @intCast(input.len),
                .scale_count = @intCast(scale_count),
                .group_size = 8,
            }
        else
            .{
                .input = input.ptr,
                .q_output = executor.shared_q8_g16[0..projection.in_f].ptr,
                .activation_scales = executor.shared_scales_g16[0..scale_count].ptr,
                .input_len = @intCast(input.len),
                .scale_count = @intCast(scale_count),
                .group_size = 16,
            };
        const slot = if (candidate.group_size == 8) &sources.g8 else &sources.g16;
        if (slot.*) |existing| {
            if (existing.input != candidate.input or
                existing.input_len != candidate.input_len)
                return TensorError.ShapeMismatch;
        } else {
            slot.* = candidate;
        }
    }
    return sources;
}

fn quantizeSealedSources(sources: SealedPreparedSet) TensorError!void {
    if (sources.g8) |source| {
        try int4_matmul.quantizeQ8Activation(
            source.input[0..source.input_len],
            source.group_size,
            source.q_output[0..source.input_len],
            source.activation_scales[0..source.scale_count],
        );
    }
    if (sources.g16) |source| {
        try int4_matmul.quantizeQ8Activation(
            source.input[0..source.input_len],
            source.group_size,
            source.q_output[0..source.input_len],
            source.activation_scales[0..source.scale_count],
        );
    }
}

fn sealProjection(
    projection: Projection,
    sources: SealedPreparedSet,
) TensorError!SealedProjection {
    if (!projection.use_q8 or projection.weights.packed_layout != .rows4_k16 or
        projection.weights.expanded_i8.len >= projection.weights.num_elements)
        return TensorError.ShapeMismatch;
    const source = sourceForGroup(sources, projection.weights.group_size) orelse
        return TensorError.ShapeMismatch;
    const recipe = try int4_matmul.PreparedQ8MatvecPlan.init(
        projection.weights,
        projection.bias,
        projection.out,
        projection.out_f,
        projection.in_f,
    );
    return .{
        .plan = try recipe.bind(
            source.q_output[0..source.input_len],
            source.activation_scales[0..source.scale_count],
        ),
        .tile_count = @intCast(projectionTileCount(projection.out_f)),
    };
}

fn validatePairedProjectionTiles(projections: []const Projection) TensorError!usize {
    if (projections.len != 2) return TensorError.ShapeMismatch;
    const first = projections[0];
    const second = projections[1];
    const first_compact = first.weights.expanded_i8.len < first.weights.num_elements;
    const second_compact = second.weights.expanded_i8.len < second.weights.num_elements;
    const first_elements = std.math.mul(usize, first.out_f, first.in_f) catch
        return TensorError.ShapeMismatch;
    const second_elements = std.math.mul(usize, second.out_f, second.in_f) catch
        return TensorError.ShapeMismatch;
    if (first.out_f == 0 or first.out_f != second.out_f or
        first.in_f != second.in_f or
        first.x.data.ptr != second.x.data.ptr or
        first.x.data.len != second.x.data.len or
        !std.mem.eql(usize, first.x.shape, second.x.shape) or
        !first.use_q8 or !second.use_q8 or
        (first.weights.group_size != 8 and first.weights.group_size != 16) or
        first.weights.group_size != second.weights.group_size or
        first.weights.packed_layout != second.weights.packed_layout or
        first_compact != second_compact or
        (first_compact and first.in_f > max_shared_input) or
        first_elements % 2 != 0 or second_elements % 2 != 0 or
        first_elements % first.weights.group_size != 0 or
        second_elements % second.weights.group_size != 0)
        return TensorError.ShapeMismatch;
    const numerator = std.math.add(usize, first.out_f, paired_tile_rows - 1) catch
        return TensorError.ShapeMismatch;
    return numerator / paired_tile_rows;
}

fn sameTensorStorage(left: Tensor, right: Tensor) bool {
    return left.dtype == right.dtype and
        left.data.ptr == right.data.ptr and
        left.data.len == right.data.len and
        std.mem.eql(usize, left.shape, right.shape);
}

fn validatePairedSiluQ8Bridge(
    graph: HandoffGraph,
    bridge: PairedSiluQ8Bridge,
) TensorError!kernels.SiluMulQuantizeQ8Plan {
    std.debug.assert(graph.mlp.len == 2);
    const hidden = graph.mlp[0].out_f;
    if (!sameTensorStorage(bridge.gate, graph.mlp[0].out) or
        !sameTensorStorage(bridge.up, graph.mlp[1].out) or
        bridge.q_output.ptr != graph.final.q_input.ptr or
        bridge.q_output.len != graph.final.q_input.len or
        bridge.activation_scales.ptr != graph.final.activation_scales.ptr or
        bridge.activation_scales.len != graph.final.activation_scales.len)
        return TensorError.ShapeMismatch;

    const activation_group_size: usize = switch (graph.final.group_size) {
        8 => 32,
        16 => 16,
        else => return TensorError.ShapeMismatch,
    };
    if (paired_tile_rows % activation_group_size != 0 or
        graph.final.q_input.len != hidden)
        return TensorError.ShapeMismatch;
    const scale_count = hidden / activation_group_size +
        @intFromBool(hidden % activation_group_size != 0);
    if (graph.final.activation_scales.len != scale_count)
        return TensorError.ShapeMismatch;
    for (graph.final.projections) |projection| {
        if (projection.in_f != hidden) return TensorError.ShapeMismatch;
    }

    const plan = try kernels.prepareSiluMulQuantizeQ8(
        bridge.gate,
        bridge.up,
        graph.final.group_size,
        bridge.q_output,
        bridge.activation_scales,
    );
    try validatePairedWriteAliases(graph, plan);
    return plan;
}

fn validateAndCountTiles(projections: []const Projection) TensorError!usize {
    var total_tiles: usize = 0;
    for (projections) |projection| {
        try validateProjection(projection);
        const projection_tiles = std.math.add(usize, projection.out_f, tile_rows - 1) catch
            return TensorError.ShapeMismatch;
        total_tiles = std.math.add(
            usize,
            total_tiles,
            projection_tiles / tile_rows,
        ) catch return TensorError.ShapeMismatch;
    }
    return total_tiles;
}

fn sharedPreparedActivation(batch: *const Batch, projection: Projection) ?PreparedActivation {
    if (!projection.use_q8 or comptime builtin.cpu.arch != .aarch64) return null;
    const shared = if (projection.weights.group_size == 8)
        batch.prepared_g8
    else if (projection.weights.group_size == 16)
        batch.prepared_g16
    else
        null;
    const compact = projection.weights.expanded_i8.len < projection.weights.num_elements;
    if ((batch.force_prepared or compact) and shared != null) return shared.?;
    return null;
}

fn byteSlicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(usize, a_start, a.len) catch return true;
    const b_end = std.math.add(usize, b_start, b.len) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn projectionReadStorageOverlaps(write: []const u8, projection: Projection) bool {
    return byteSlicesOverlap(write, projection.x.data) or
        projectionPersistentStorageOverlaps(write, projection);
}

fn projectionPersistentStorageOverlaps(write: []const u8, projection: Projection) bool {
    return byteSlicesOverlap(write, std.mem.sliceAsBytes(projection.x.shape)) or
        byteSlicesOverlap(write, std.mem.sliceAsBytes(projection.out.shape)) or
        byteSlicesOverlap(write, std.mem.sliceAsBytes(projection.bias)) or
        byteSlicesOverlap(write, projection.weights.packed_bytes) or
        byteSlicesOverlap(write, std.mem.sliceAsBytes(projection.weights.scales)) or
        byteSlicesOverlap(write, std.mem.sliceAsBytes(projection.weights.scales_f16)) or
        byteSlicesOverlap(write, std.mem.sliceAsBytes(projection.weights.scales_f16_rows4)) or
        byteSlicesOverlap(write, std.mem.sliceAsBytes(projection.weights.expanded_i8));
}

fn validateWritesAgainstProjections(
    first_write: []const u8,
    second_write: []const u8,
    projections: []const Projection,
) TensorError!void {
    const descriptors = std.mem.sliceAsBytes(projections);
    if (byteSlicesOverlap(first_write, descriptors) or
        byteSlicesOverlap(second_write, descriptors))
        return TensorError.ShapeMismatch;
    for (projections) |projection| {
        if (projectionReadStorageOverlaps(first_write, projection) or
            projectionReadStorageOverlaps(second_write, projection) or
            byteSlicesOverlap(first_write, projection.out.data) or
            byteSlicesOverlap(second_write, projection.out.data))
            return TensorError.ShapeMismatch;
    }
}

fn validateProjectionWritesAgainstPersistentStorage(
    writes: []const Projection,
    peers: []const Projection,
) TensorError!void {
    const descriptors = std.mem.sliceAsBytes(peers);
    for (writes) |projection| {
        if (byteSlicesOverlap(projection.out.data, descriptors))
            return TensorError.ShapeMismatch;
        for (peers) |peer| {
            if (projectionPersistentStorageOverlaps(projection.out.data, peer))
                return TensorError.ShapeMismatch;
        }
    }
}

/// Graph projections are reusable across tokens. No phase output may corrupt
/// immutable weights, tensor metadata, or a projection descriptor, even when
/// the affected phase has already completed in the current invocation.
fn validateGraphPersistentAliases(graph: HandoffGraph) TensorError!void {
    const phases = [_][]const Projection{
        graph.qkv,
        graph.output,
        graph.mlp,
        graph.final.projections,
    };
    for (phases) |writes| {
        for (phases) |peers|
            try validateProjectionWritesAgainstPersistentStorage(writes, peers);
    }
}

fn validatePairedWriteAliases(
    graph: HandoffGraph,
    plan: kernels.SiluMulQuantizeQ8Plan,
) TensorError!void {
    const q_bytes = std.mem.sliceAsBytes(plan.q_output);
    const scale_bytes = std.mem.sliceAsBytes(plan.activation_scales);
    try validateWritesAgainstProjections(q_bytes, scale_bytes, graph.qkv);
    try validateWritesAgainstProjections(q_bytes, scale_bytes, graph.output);
    try validateWritesAgainstProjections(q_bytes, scale_bytes, graph.mlp);
    try validateWritesAgainstProjections(q_bytes, scale_bytes, graph.final.projections);
}

fn validatePairedExecutorScratchAliases(
    executor: *const Executor,
    plan: kernels.SiluMulQuantizeQ8Plan,
) TensorError!void {
    return validateExecutorStorageAgainstSlices(
        executor,
        std.mem.sliceAsBytes(plan.q_output),
        std.mem.sliceAsBytes(plan.activation_scales),
    );
}

fn executorStorage(executor: *const Executor) [4][]const u8 {
    return .{
        std.mem.asBytes(executor),
        std.mem.sliceAsBytes(executor.threads),
        std.mem.sliceAsBytes(executor.greedy_argmax_candidates),
        if (executor.pair_scratch_backing) |backing|
            std.mem.sliceAsBytes(backing)
        else
            &.{},
    };
}

fn validateGreedyArgmaxProjection(
    executor: *const Executor,
    input: Tensor,
    weights: int4_weights.Int4WeightData,
    out_f: usize,
    in_f: usize,
) TensorError!GreedyArgmaxGeometry {
    if (out_f == 0 or in_f == 0 or in_f > max_shared_input or
        out_f % 4 != 0 or in_f % 16 != 0 or
        (weights.group_size != 8 and weights.group_size != 16) or
        in_f % weights.group_size != 0 or
        weights.packed_layout != .rows4_k16 or
        weights.expanded_i8.len != 0)
        return TensorError.ShapeMismatch;
    const expected = std.math.mul(usize, out_f, in_f) catch
        return TensorError.ShapeMismatch;
    const packed_count = expected / 2;
    const scale_count = expected / weights.group_size;
    if (weights.num_elements != expected or
        weights.packed_bytes.len < packed_count or
        weights.scales_f16_rows4.len < scale_count)
        return TensorError.ShapeMismatch;

    const input_elements = try checkedF32ElementCount(input);
    if (input_elements != in_f or input.shape.len != 2 or
        input.shape[0] != 1 or input.shape[1] != in_f)
        return TensorError.ShapeMismatch;

    const input_bytes = input.data;
    const shape_bytes = std.mem.sliceAsBytes(input.shape);
    const packed_bytes = weights.packed_bytes[0..packed_count];
    const scale_bytes = std.mem.sliceAsBytes(
        weights.scales_f16_rows4[0..scale_count],
    );
    for (executorStorage(executor)) |storage| {
        if (byteSlicesOverlap(storage, input_bytes) or
            byteSlicesOverlap(storage, shape_bytes) or
            byteSlicesOverlap(storage, packed_bytes) or
            byteSlicesOverlap(storage, scale_bytes))
            return TensorError.ShapeMismatch;
    }

    const tile_numerator = std.math.add(
        usize,
        out_f,
        greedy_argmax_tile_rows - 1,
    ) catch return TensorError.ShapeMismatch;
    return .{
        .tile_count = tile_numerator / greedy_argmax_tile_rows,
        .packed_bytes_per_row = in_f / 2,
        .scales_per_row = in_f / weights.group_size,
    };
}

fn validateEligibleWords(
    executor: *const Executor,
    eligible_words: []const u64,
    out_f: usize,
) TensorError!usize {
    const word_count = out_f / 64 + @intFromBool(out_f % 64 != 0);
    if (word_count == 0 or eligible_words.len != word_count)
        return TensorError.ShapeMismatch;
    if (out_f % 64 != 0) {
        const tail_bits: u6 = @intCast(out_f % 64);
        const valid = (@as(u64, 1) << tail_bits) - 1;
        if (eligible_words[word_count - 1] & ~valid != 0)
            return TensorError.ShapeMismatch;
    }
    try validateExecutorStorageAgainstSlices(
        executor,
        std.mem.sliceAsBytes(eligible_words),
        &.{},
    );
    var eligible_rows: usize = 0;
    for (eligible_words) |word| {
        eligible_rows = std.math.add(
            usize,
            eligible_rows,
            @popCount(word),
        ) catch return TensorError.ShapeMismatch;
    }
    if (eligible_rows == 0 or eligible_rows > out_f)
        return TensorError.ShapeMismatch;
    return eligible_rows;
}

/// The executor is public and owns mutable synchronization state as well as
/// activation scratch. Reject every projection read/write/descriptor that
/// points into either the inline object or its worker-handle allocation before
/// dispatch can mutate `generation`, `current`, conditions, or scratch.
fn validateExecutorStorageAgainstProjections(
    executor: *const Executor,
    projections: []const Projection,
) TensorError!void {
    const descriptors = std.mem.sliceAsBytes(projections);
    for (executorStorage(executor)) |storage| {
        if (byteSlicesOverlap(storage, descriptors))
            return TensorError.ShapeMismatch;
        for (projections) |projection| {
            if (projectionReadStorageOverlaps(storage, projection) or
                byteSlicesOverlap(storage, projection.out.data))
                return TensorError.ShapeMismatch;
        }
    }
}

fn validateExecutorStorageAgainstSlices(
    executor: *const Executor,
    first: []const u8,
    second: []const u8,
) TensorError!void {
    for (executorStorage(executor)) |storage| {
        if (byteSlicesOverlap(storage, first) or byteSlicesOverlap(storage, second))
            return TensorError.ShapeMismatch;
    }
}

fn validatePairNibbleProjection(
    executor: *const Executor,
    projection: PairNibbleProjection,
) TensorError!int4_matmul.PreparedPairNibbleQ8Plan {
    if (projection.out_f == 0 or projection.in_f == 0 or
        projection.in_f > max_shared_input or projection.out_f % 4 != 0 or
        projection.in_f % 16 != 0 or
        projection.weights.out_f != projection.out_f or
        projection.weights.in_f != projection.in_f or
        (projection.gate_bias.len != 0 and
            projection.gate_bias.len != projection.out_f) or
        (projection.up_bias.len != 0 and
            projection.up_bias.len != projection.out_f))
        return TensorError.ShapeMismatch;
    int4_weights.validatePairNibble(projection.weights) catch
        return TensorError.ShapeMismatch;

    const input_elements = try checkedF32ElementCount(projection.x);
    const gate_elements = try checkedF32ElementCount(projection.gate_out);
    const up_elements = try checkedF32ElementCount(projection.up_out);
    if (input_elements != projection.in_f or
        gate_elements != projection.out_f or
        up_elements != projection.out_f or
        projection.x.shape.len != 2 or projection.x.shape[0] != 1 or
        projection.x.shape[1] != projection.in_f or
        projection.gate_out.shape.len != 2 or
        projection.gate_out.shape[0] != 1 or
        projection.gate_out.shape[1] != projection.out_f or
        projection.up_out.shape.len != 2 or
        projection.up_out.shape[0] != 1 or
        projection.up_out.shape[1] != projection.out_f)
        return TensorError.ShapeMismatch;

    const recipe = try int4_matmul.PreparedPairNibbleQ8Plan.init(
        projection.weights,
        projection.gate_bias,
        projection.up_bias,
        projection.gate_out.asF32(),
        projection.up_out.asF32(),
        1,
        projection.out_f,
    );

    const gate_write = projection.gate_out.data;
    const up_write = projection.up_out.data;
    const persistent_reads = [_][]const u8{
        projection.x.data,
        std.mem.sliceAsBytes(projection.x.shape),
        std.mem.sliceAsBytes(projection.gate_out.shape),
        std.mem.sliceAsBytes(projection.up_out.shape),
        projection.weights.paired_bytes,
        std.mem.sliceAsBytes(projection.weights.scales_f16_pairs),
        std.mem.sliceAsBytes(projection.gate_bias),
        std.mem.sliceAsBytes(projection.up_bias),
    };
    for (persistent_reads) |read| {
        if (byteSlicesOverlap(gate_write, read) or
            byteSlicesOverlap(up_write, read))
            return TensorError.ShapeMismatch;
    }
    for (executorStorage(executor)) |storage| {
        if (byteSlicesOverlap(storage, gate_write) or
            byteSlicesOverlap(storage, up_write))
            return TensorError.ShapeMismatch;
        for (persistent_reads) |read| {
            if (byteSlicesOverlap(storage, read))
                return TensorError.ShapeMismatch;
        }
    }
    return recipe;
}

fn validatePairNibbleSiluQ8Projection(
    executor: *const Executor,
    projection: PairNibbleSiluQ8Projection,
) TensorError!ValidatedPairNibbleSiluQ8Projection {
    if (projection.out_f == 0 or projection.in_f == 0 or
        projection.in_f > max_shared_input or projection.out_f % 4 != 0 or
        projection.in_f % 16 != 0 or
        projection.weights.out_f != projection.out_f or
        projection.weights.in_f != projection.in_f or
        (projection.down_group_size != 8 and
            projection.down_group_size != 16))
        return TensorError.ShapeMismatch;
    const input_elements = try checkedF32ElementCount(projection.x);
    if (input_elements != projection.in_f or projection.x.shape.len != 2 or
        projection.x.shape[0] != 1 or
        projection.x.shape[1] != projection.in_f)
        return TensorError.ShapeMismatch;
    const output_scale_count = int4_matmul.q8ActivationScaleCount(
        projection.out_f,
        projection.down_group_size,
    );
    if (projection.q_output.len != projection.out_f or
        projection.activation_scales.len != output_scale_count)
        return TensorError.ShapeMismatch;

    const recipe = try int4_matmul.PreparedPairNibbleQ8TilePlan.init(
        projection.weights,
        projection.gate_bias,
        projection.up_bias,
    );
    const q_write = std.mem.sliceAsBytes(projection.q_output);
    const scale_write = std.mem.sliceAsBytes(projection.activation_scales);
    if (byteSlicesOverlap(q_write, scale_write))
        return TensorError.ShapeMismatch;
    const persistent_reads = [_][]const u8{
        projection.x.data,
        std.mem.sliceAsBytes(projection.x.shape),
        recipe.paired_weights,
        std.mem.sliceAsBytes(recipe.paired_scales),
        std.mem.sliceAsBytes(recipe.gate_bias),
        std.mem.sliceAsBytes(recipe.up_bias),
    };
    for (persistent_reads) |read| {
        if (byteSlicesOverlap(q_write, read) or
            byteSlicesOverlap(scale_write, read))
            return TensorError.ShapeMismatch;
    }
    for (executorStorage(executor)) |storage| {
        if (byteSlicesOverlap(storage, q_write) or
            byteSlicesOverlap(storage, scale_write))
            return TensorError.ShapeMismatch;
        for (persistent_reads) |read| {
            if (byteSlicesOverlap(storage, read))
                return TensorError.ShapeMismatch;
        }
    }
    return .{
        .recipe = recipe,
        .input = projection.x.asF32(),
        .q_output = projection.q_output,
        .output_scales = projection.activation_scales,
        .down_group_size = projection.down_group_size,
    };
}

/// Validate the x-less prepared-down contract before the Pair producer can
/// write Q8 scratch. This deliberately does not reuse `validateProjection`:
/// requiring a fake f32 input there would retain one hidden-width allocation
/// and would make the compact frame's storage claim false.
fn validatePairNibblePreparedDownProjection(
    executor: *const Executor,
    projection: PairNibblePreparedDownProjection,
    q_input: []const i8,
    activation_scales: []const f32,
) TensorError!int4_matmul.PreparedQ8MatvecPlan {
    if (projection.out_f == 0 or projection.in_f == 0 or
        projection.in_f > max_shared_input or
        projection.out_f % 4 != 0 or projection.in_f % 16 != 0 or
        (projection.weights.group_size != 8 and
            projection.weights.group_size != 16) or
        projection.weights.packed_layout != .rows4_k16 or
        projection.weights.expanded_i8.len != 0)
        return TensorError.ShapeMismatch;
    const scale_count = int4_matmul.q8ActivationScaleCount(
        projection.in_f,
        projection.weights.group_size,
    );
    if (q_input.len != projection.in_f or
        activation_scales.len != scale_count)
        return TensorError.ShapeMismatch;

    const recipe = try int4_matmul.PreparedQ8MatvecPlan.init(
        projection.weights,
        projection.bias,
        projection.out,
        projection.out_f,
        projection.in_f,
    );
    const descriptor = std.mem.asBytes(&projection);
    const q_bytes = std.mem.sliceAsBytes(q_input);
    const scale_bytes = std.mem.sliceAsBytes(activation_scales);
    const output_bytes = projection.out.data;
    const persistent_reads = [_][]const u8{
        std.mem.sliceAsBytes(projection.out.shape),
        std.mem.sliceAsBytes(projection.bias),
        projection.weights.packed_bytes,
        std.mem.sliceAsBytes(projection.weights.scales),
        std.mem.sliceAsBytes(projection.weights.scales_f16),
        std.mem.sliceAsBytes(projection.weights.scales_f16_rows4),
        std.mem.sliceAsBytes(projection.weights.expanded_i8),
    };
    if (byteSlicesOverlap(q_bytes, scale_bytes) or
        byteSlicesOverlap(q_bytes, output_bytes) or
        byteSlicesOverlap(scale_bytes, output_bytes) or
        byteSlicesOverlap(q_bytes, descriptor) or
        byteSlicesOverlap(scale_bytes, descriptor) or
        byteSlicesOverlap(output_bytes, descriptor))
        return TensorError.ShapeMismatch;
    for (persistent_reads) |read| {
        if (byteSlicesOverlap(q_bytes, read) or
            byteSlicesOverlap(scale_bytes, read) or
            byteSlicesOverlap(output_bytes, read))
            return TensorError.ShapeMismatch;
    }
    for (executorStorage(executor)) |storage| {
        if (byteSlicesOverlap(storage, descriptor) or
            byteSlicesOverlap(storage, q_bytes) or
            byteSlicesOverlap(storage, scale_bytes) or
            byteSlicesOverlap(storage, output_bytes))
            return TensorError.ShapeMismatch;
        for (persistent_reads) |read| {
            if (byteSlicesOverlap(storage, read))
                return TensorError.ShapeMismatch;
        }
    }
    return recipe;
}

/// Projection outputs within one parallel phase must be pairwise disjoint and
/// may not overwrite any activation still being read by that phase.
fn validatePhaseAliases(projections: []const Projection) TensorError!void {
    const descriptors = std.mem.sliceAsBytes(projections);
    for (projections, 0..) |projection, projection_index| {
        if (byteSlicesOverlap(projection.out.data, descriptors))
            return TensorError.ShapeMismatch;
        for (projections) |peer| {
            if (projectionReadStorageOverlaps(projection.out.data, peer))
                return TensorError.ShapeMismatch;
        }
        for (projections[projection_index + 1 ..]) |peer| {
            if (byteSlicesOverlap(projection.out.data, peer.out.data))
                return TensorError.ShapeMismatch;
        }
    }
}

fn validatePreparedSliceAliases(
    projections: []const Projection,
    q_input: []const i8,
    activation_scales: []const f32,
) TensorError!void {
    const q_bytes = std.mem.sliceAsBytes(q_input);
    const scale_bytes = std.mem.sliceAsBytes(activation_scales);
    if (byteSlicesOverlap(q_bytes, scale_bytes)) return TensorError.ShapeMismatch;
    const descriptors = std.mem.sliceAsBytes(projections);
    if (byteSlicesOverlap(q_bytes, descriptors) or
        byteSlicesOverlap(scale_bytes, descriptors))
        return TensorError.ShapeMismatch;
    for (projections) |projection| {
        if (projectionReadStorageOverlaps(q_bytes, projection) or
            projectionReadStorageOverlaps(scale_bytes, projection) or
            byteSlicesOverlap(projection.out.data, q_bytes) or
            byteSlicesOverlap(projection.out.data, scale_bytes))
            return TensorError.ShapeMismatch;
    }
}

fn validatePreparedAliases(batch: PreparedProjectionBatch) TensorError!void {
    return validatePreparedSliceAliases(
        batch.projections,
        batch.q_input,
        batch.activation_scales,
    );
}

fn runBatchWorker(batch: *Batch) TensorError!void {
    if (batch.sealed_projections.len != 0)
        return runSealedBatchWorker(batch);
    var q_values: [16384]i8 = undefined;
    var activation_scales: [2048]f32 = undefined;
    var prepared_input: ?[*]const f32 = null;
    var prepared_in_f: usize = 0;
    var prepared_group_size: u32 = 0;
    while (true) {
        var tile_idx = batch.next_tile.fetchAdd(1, .monotonic);
        if (tile_idx >= batch.total_tiles) return;
        var projection_idx: usize = 0;
        while (projection_idx < batch.projections.len) : (projection_idx += 1) {
            const projection_tiles =
                (batch.projections[projection_idx].out_f + tile_rows - 1) / tile_rows;
            if (tile_idx < projection_tiles) break;
            tile_idx -= projection_tiles;
        }
        if (projection_idx == batch.projections.len) return TensorError.ShapeMismatch;
        const projection = batch.projections[projection_idx];
        const out_start = tile_idx * tile_rows;
        const out_end = @min(out_start + tile_rows, projection.out_f);
        var prepared: ?PreparedActivation = null;
        if (projection.use_q8 and comptime builtin.cpu.arch == .aarch64) {
            const shared = if (projection.weights.group_size == 8)
                batch.prepared_g8
            else if (projection.weights.group_size == 16)
                batch.prepared_g16
            else
                null;
            const compact = projection.weights.expanded_i8.len <
                projection.weights.num_elements;
            if ((batch.force_prepared or compact) and shared != null) {
                prepared = shared.?;
            } else if (compact and
                projection.in_f <= q_values.len and
                (projection.weights.group_size == 8 or projection.weights.group_size == 16))
            {
                const input = projection.x.asF32();
                const scale_count = int4_matmul.q8ActivationScaleCount(
                    projection.in_f,
                    projection.weights.group_size,
                );
                if (prepared_input == null or prepared_input.? != input.ptr or
                    prepared_in_f != projection.in_f or
                    prepared_group_size != projection.weights.group_size)
                {
                    try int4_matmul.quantizeQ8Activation(
                        input,
                        projection.weights.group_size,
                        q_values[0..projection.in_f],
                        activation_scales[0..scale_count],
                    );
                    prepared_input = input.ptr;
                    prepared_in_f = projection.in_f;
                    prepared_group_size = projection.weights.group_size;
                }
                prepared = .{
                    .q_input = q_values[0..projection.in_f],
                    .scales = activation_scales[0..scale_count],
                };
            }
        }
        try runProjectionRange(projection, out_start, out_end, prepared);
    }
}

fn runSealedBatchWorker(batch: *Batch) TensorError!void {
    while (true) {
        var tile_index = batch.next_tile.fetchAdd(1, .monotonic);
        if (tile_index >= batch.total_tiles) return;
        var projection_index: usize = 0;
        while (projection_index < batch.sealed_projections.len) : (projection_index += 1) {
            const projection_tiles: usize =
                batch.sealed_projections[projection_index].tile_count;
            if (tile_index < projection_tiles) break;
            tile_index -= projection_tiles;
        }
        if (projection_index == batch.sealed_projections.len)
            return TensorError.ShapeMismatch;
        const projection = batch.sealed_projections[projection_index];
        const row_start = tile_index * tile_rows;
        const row_end = @min(
            row_start + tile_rows,
            @as(usize, projection.plan.recipe.out_f),
        );
        runSealedProjectionRows(projection, row_start, row_end);
    }
}

fn runPairedProjectionWorker(
    batch: *Batch,
    plan: kernels.SiluMulQuantizeQ8Plan,
) TensorError!void {
    if (batch.sealed_projections.len != 0)
        return runSealedPairedProjectionWorker(batch, plan);
    std.debug.assert(batch.projections.len == 2);
    const first_prepared = sharedPreparedActivation(batch, batch.projections[0]);
    const second_prepared = sharedPreparedActivation(batch, batch.projections[1]);
    const compact = batch.projections[0].weights.expanded_i8.len <
        batch.projections[0].weights.num_elements;
    if (compact and (first_prepared == null or second_prepared == null))
        return TensorError.ShapeMismatch;

    while (true) {
        const tile_index = batch.next_tile.fetchAdd(1, .monotonic);
        if (tile_index >= batch.total_tiles) return;
        if (comptime builtin.is_test) {
            if (batch.test_tile_visits) |visits| {
                if (tile_index >= visits.len or
                    visits[tile_index].fetchAdd(1, .monotonic) != 0)
                    return TensorError.ShapeMismatch;
            }
        }
        const element_start = tile_index * paired_tile_rows;
        const element_end = @min(
            element_start + paired_tile_rows,
            batch.projections[0].out_f,
        );
        try runProjectionRange(
            batch.projections[0],
            element_start,
            element_end,
            first_prepared,
        );
        try runProjectionRange(
            batch.projections[1],
            element_start,
            element_end,
            second_prepared,
        );
        try plan.runElementRange(element_start, element_end);
    }
}

fn runSealedPairedProjectionWorker(
    batch: *Batch,
    plan: kernels.SiluMulQuantizeQ8Plan,
) TensorError!void {
    if (batch.sealed_projections.len != 2)
        return TensorError.ShapeMismatch;
    while (true) {
        const tile_index = batch.next_tile.fetchAdd(1, .monotonic);
        if (tile_index >= batch.total_tiles) return;
        const element_start = tile_index * paired_tile_rows;
        const element_end = @min(
            element_start + paired_tile_rows,
            @as(usize, batch.sealed_projections[0].plan.recipe.out_f),
        );
        runSealedProjectionRows(
            batch.sealed_projections[0],
            element_start,
            element_end,
        );
        runSealedProjectionRows(
            batch.sealed_projections[1],
            element_start,
            element_end,
        );
        try plan.runElementRange(element_start, element_end);
    }
}

/// Executor-private unchecked kernel edge. Only sealed tile schedulers call
/// this after one-time recipe validation and finalization; the public matmul
/// API retains checked ranges and architecture failure semantics.
inline fn runSealedProjectionRows(
    projection: SealedProjection,
    row_start: usize,
    row_end: usize,
) void {
    const bound = projection.plan;
    const recipe = bound.recipe;
    const out_f: usize = recipe.out_f;
    const in_f: usize = recipe.in_f;
    const group_size: usize = recipe.group_size;
    std.debug.assert(row_start < row_end and row_end <= out_f);
    std.debug.assert(row_start % 4 == 0 and row_end % 4 == 0);
    const packed_start = row_start * @as(usize, recipe.packed_bytes_per_row);
    const scale_start = row_start * @as(usize, recipe.scales_per_row);
    const bias_ptr: ?[*]const f32 = if (recipe.bias) |bias|
        bias + row_start
    else
        null;
    if (comptime builtin.cpu.arch == .aarch64) {
        glacier_int4_matvec_neon_q8_prequant_f16scale_rows4_k16(
            bound.q_input,
            bound.activation_scales,
            recipe.packed_weights + packed_start,
            recipe.scales + scale_start,
            bias_ptr,
            recipe.output + row_start,
            row_end - row_start,
            in_f,
            group_size,
        );
    } else {
        unreachable;
    }
}

fn checkedF32ElementCount(value: Tensor) TensorError!usize {
    if (value.dtype != .f32) return TensorError.DTypeUnsupported;
    var element_count: usize = 1;
    for (value.shape) |dimension| {
        element_count = std.math.mul(usize, element_count, dimension) catch
            return TensorError.ShapeMismatch;
    }
    const expected_bytes = std.math.mul(usize, element_count, @sizeOf(f32)) catch
        return TensorError.ShapeMismatch;
    if (value.data.len != expected_bytes or
        (element_count != 0 and @intFromPtr(value.data.ptr) % @alignOf(f32) != 0))
        return TensorError.ShapeMismatch;
    return element_count;
}

fn validateProjection(projection: Projection) TensorError!void {
    const expected = std.math.mul(usize, projection.out_f, projection.in_f) catch
        return TensorError.ShapeMismatch;
    if (projection.weights.num_elements != expected or projection.weights.group_size == 0)
        return TensorError.ShapeMismatch;
    const group_size: usize = projection.weights.group_size;
    const tile_elements = std.math.mul(usize, tile_rows, projection.in_f) catch
        return TensorError.ShapeMismatch;
    if (expected % 2 != 0 or expected % group_size != 0 or
        (projection.use_q8 and projection.in_f % group_size != 0) or
        (projection.out_f > tile_rows and
            (tile_elements % 2 != 0 or tile_elements % group_size != 0)))
        return TensorError.ShapeMismatch;
    if (projection.weights.packed_layout == .rows4_k16 and
        (projection.out_f % 4 != 0 or projection.in_f % 16 != 0 or
            projection.weights.scales_f16_rows4.len == 0))
        return TensorError.ShapeMismatch;
    const x_elements = try checkedF32ElementCount(projection.x);
    const out_elements = try checkedF32ElementCount(projection.out);
    if (x_elements != projection.in_f or out_elements != projection.out_f or
        projection.x.shape.len != 2 or projection.x.shape[0] != 1 or
        projection.x.shape[1] != projection.in_f or projection.out.shape.len != 2 or
        projection.out.shape[0] != 1 or projection.out.shape[1] != projection.out_f or
        (projection.bias.len != 0 and projection.bias.len != projection.out_f))
        return TensorError.ShapeMismatch;

    const packed_count = expected / 2 + @intFromBool(expected % 2 != 0);
    const scale_count = expected / group_size + @intFromBool(expected % group_size != 0);
    const has_f32_scales = projection.weights.scales.len >= scale_count;
    const has_f16_scales = projection.weights.scales_f16.len >= scale_count;
    const has_rows4_scales = projection.weights.scales_f16_rows4.len >= scale_count;
    const has_q8_scales = has_f32_scales or has_f16_scales or has_rows4_scales;
    if (projection.weights.packed_bytes.len < packed_count or
        (projection.use_q8 and !has_q8_scales) or
        (!projection.use_q8 and projection.weights.scales.len < scale_count) or
        (projection.weights.scales_f16.len != 0 and
            projection.weights.scales_f16.len < scale_count) or
        (projection.weights.scales_f16_rows4.len != 0 and
            projection.weights.scales_f16_rows4.len < scale_count) or
        (projection.weights.expanded_i8.len != 0 and
            projection.weights.expanded_i8.len < expected))
        return TensorError.ShapeMismatch;

    // Match the kernel selected by `runProjectionRange` before any worker can
    // write. FP32 activation decode and every portable Q8 fallback require
    // row-major packed weights plus FP32 scales. The rows4/F16-only formats are
    // valid solely for the eligible AArch64 Q8 kernels.
    switch (projection.weights.packed_layout) {
        .rows4_k16 => {
            if (!projection.use_q8 or builtin.cpu.arch != .aarch64 or
                (projection.weights.group_size != 8 and
                    projection.weights.group_size != 16) or
                projection.in_f % 16 != 0 or projection.out_f % 4 != 0 or
                !has_rows4_scales)
                return TensorError.ShapeMismatch;
        },
        .row_major => {
            if (!projection.use_q8 and !has_f32_scales)
                return TensorError.ShapeMismatch;
            if (projection.use_q8 and !has_f32_scales) {
                const aarch64_f16_kernel = builtin.cpu.arch == .aarch64 and
                    (projection.weights.group_size == 8 or
                        projection.weights.group_size == 16) and
                    projection.in_f % 16 == 0 and
                    (has_f16_scales or
                        (has_rows4_scales and projection.out_f % 4 == 0));
                if (!aarch64_f16_kernel) return TensorError.ShapeMismatch;
            }
        },
    }
}

const ProjectionRange = struct {
    weights: int4_weights.Int4WeightData,
    bias: []const f32,
    out: Tensor,
    row_count: usize,
};

fn projectionRange(
    projection: Projection,
    out_start: usize,
    out_end: usize,
    out_shape: *[2]usize,
) TensorError!ProjectionRange {
    const expected = std.math.mul(usize, projection.out_f, projection.in_f) catch
        return TensorError.ShapeMismatch;
    if (projection.weights.num_elements != expected or projection.weights.group_size == 0)
        return TensorError.ShapeMismatch;
    if (projection.x.shape.len != 2 or projection.x.shape[0] != 1 or
        projection.x.shape[1] != projection.in_f or projection.out.shape.len != 2 or
        projection.out.shape[0] != 1 or projection.out.shape[1] != projection.out_f or
        (projection.bias.len != 0 and projection.bias.len != projection.out_f))
        return TensorError.ShapeMismatch;

    if (out_start >= out_end or out_end > projection.out_f) return TensorError.ShapeMismatch;
    const start_element = std.math.mul(usize, out_start, projection.in_f) catch
        return TensorError.ShapeMismatch;
    const end_element = std.math.mul(usize, out_end, projection.in_f) catch
        return TensorError.ShapeMismatch;
    const group_size: usize = projection.weights.group_size;
    if (start_element % 2 != 0 or end_element % 2 != 0 or
        start_element % group_size != 0 or end_element % group_size != 0)
        return TensorError.ShapeMismatch;

    const packed_start = start_element / 2;
    const packed_end = end_element / 2;
    const scale_start = start_element / group_size;
    const scale_end = end_element / group_size;
    const row_count = out_end - out_start;
    out_shape.* = .{ 1, row_count };
    const byte_start = std.math.mul(usize, out_start, @sizeOf(f32)) catch
        return TensorError.ShapeMismatch;
    const byte_end = std.math.mul(usize, out_end, @sizeOf(f32)) catch
        return TensorError.ShapeMismatch;
    const out_view: Tensor = .{
        .dtype = .f32,
        .shape = out_shape,
        .data = projection.out.data[byte_start..byte_end],
        .allocator = std.heap.page_allocator,
    };
    const sub_weights: int4_weights.Int4WeightData = .{
        .packed_bytes = projection.weights.packed_bytes[packed_start..packed_end],
        .scales = if (projection.weights.scales.len == 0)
            &.{}
        else
            projection.weights.scales[scale_start..scale_end],
        .scales_f16 = if (projection.weights.scales_f16.len == 0)
            &.{}
        else
            projection.weights.scales_f16[scale_start..scale_end],
        .scales_f16_rows4 = if (projection.weights.scales_f16_rows4.len == 0)
            &.{}
        else
            projection.weights.scales_f16_rows4[scale_start..scale_end],
        .expanded_i8 = if (projection.weights.expanded_i8.len == 0)
            &.{}
        else
            projection.weights.expanded_i8[start_element..end_element],
        .group_size = projection.weights.group_size,
        .num_elements = end_element - start_element,
        .packed_layout = projection.weights.packed_layout,
    };
    const sub_bias = if (projection.bias.len == 0)
        &.{}
    else
        projection.bias[out_start..out_end];
    return .{
        .weights = sub_weights,
        .bias = sub_bias,
        .out = out_view,
        .row_count = row_count,
    };
}

fn runProjectionRange(
    projection: Projection,
    out_start: usize,
    out_end: usize,
    prepared: ?PreparedActivation,
) TensorError!void {
    var out_shape: [2]usize = undefined;
    const range = try projectionRange(projection, out_start, out_end, &out_shape);
    if (projection.use_q8) {
        if (prepared) |activation| {
            return int4_matmul.linearInt4WeightQ8Prepared(
                activation.q_input,
                activation.scales,
                range.weights,
                range.bias,
                range.out,
                range.row_count,
                projection.in_f,
            );
        }
        return int4_matmul.linearInt4WeightQ8(
            projection.x,
            range.weights,
            range.bias,
            range.out,
            range.row_count,
            projection.in_f,
        );
    }
    return int4_matmul.linearInt4Weight(
        projection.x,
        range.weights,
        range.bias,
        range.out,
        range.row_count,
        projection.in_f,
    );
}

const PairExecutorTestFixture = struct {
    allocator: std.mem.Allocator,
    gate_packed: []u8,
    up_packed: []u8,
    gate_scales: []f16,
    up_scales: []f16,
    paired_bytes: []u8,
    paired_scales: []f16,
    gate_bias: []f32,
    up_bias: []f32,
    gate_weights: int4_weights.Int4WeightData,
    up_weights: int4_weights.Int4WeightData,
    pair: int4_weights.PairNibbleWeightData,

    fn init(
        allocator: std.mem.Allocator,
        out_f: usize,
        in_f: usize,
        group_size: usize,
    ) !PairExecutorTestFixture {
        const elements = try std.math.mul(usize, out_f, in_f);
        const packed_count = elements / 2;
        const scale_count = elements / group_size;
        const gate_packed = try allocator.alloc(u8, packed_count);
        errdefer allocator.free(gate_packed);
        const up_packed = try allocator.alloc(u8, packed_count);
        errdefer allocator.free(up_packed);
        const gate_scales = try allocator.alloc(f16, scale_count);
        errdefer allocator.free(gate_scales);
        const up_scales = try allocator.alloc(f16, scale_count);
        errdefer allocator.free(up_scales);
        const paired_bytes = try allocator.alloc(u8, elements);
        errdefer allocator.free(paired_bytes);
        const paired_scales = try allocator.alloc(f16, scale_count * 2);
        errdefer allocator.free(paired_scales);
        const gate_bias = try allocator.alloc(f32, out_f);
        errdefer allocator.free(gate_bias);
        const up_bias = try allocator.alloc(f32, out_f);
        errdefer allocator.free(up_bias);

        for (gate_packed, up_packed, 0..) |*gate, *up, index| {
            const gate_low: u8 = @intCast((index * 5 + in_f + 1) % 16);
            const gate_high: u8 = @intCast((index * 11 + out_f + 3) % 16);
            const up_low: u8 = @intCast((index * 7 + in_f + 9) % 16);
            const up_high: u8 = @intCast((index * 13 + out_f + 5) % 16);
            gate.* = gate_low | (gate_high << 4);
            up.* = up_low | (up_high << 4);
        }
        for (gate_scales, up_scales, 0..) |*gate, *up, index| {
            gate.* = @floatCast(
                (@as(f32, @floatFromInt(index % 11)) + 1.0) / 64.0,
            );
            up.* = @floatCast(
                (@as(f32, @floatFromInt(index % 13)) + 1.0) / 80.0,
            );
        }
        for (gate_bias, up_bias, 0..) |*gate, *up, index| {
            gate.* = (@as(f32, @floatFromInt(index % 17)) - 8.0) / 127.0;
            up.* = (@as(f32, @floatFromInt(index % 19)) - 9.0) / 131.0;
        }
        const gate_weights: int4_weights.Int4WeightData = .{
            .packed_bytes = gate_packed,
            .scales = &.{},
            .scales_f16_rows4 = gate_scales,
            .group_size = @intCast(group_size),
            .num_elements = elements,
            .packed_layout = .rows4_k16,
        };
        const up_weights: int4_weights.Int4WeightData = .{
            .packed_bytes = up_packed,
            .scales = &.{},
            .scales_f16_rows4 = up_scales,
            .group_size = @intCast(group_size),
            .num_elements = elements,
            .packed_layout = .rows4_k16,
        };
        const pair = try int4_weights.pairRows4K16(
            gate_weights,
            up_weights,
            out_f,
            paired_bytes,
            paired_scales,
        );
        return .{
            .allocator = allocator,
            .gate_packed = gate_packed,
            .up_packed = up_packed,
            .gate_scales = gate_scales,
            .up_scales = up_scales,
            .paired_bytes = paired_bytes,
            .paired_scales = paired_scales,
            .gate_bias = gate_bias,
            .up_bias = up_bias,
            .gate_weights = gate_weights,
            .up_weights = up_weights,
            .pair = pair,
        };
    }

    fn deinit(self: *PairExecutorTestFixture) void {
        self.allocator.free(self.up_bias);
        self.allocator.free(self.gate_bias);
        self.allocator.free(self.paired_scales);
        self.allocator.free(self.paired_bytes);
        self.allocator.free(self.up_scales);
        self.allocator.free(self.gate_scales);
        self.allocator.free(self.up_packed);
        self.allocator.free(self.gate_packed);
    }
};

test "executor instance reservation saturates without wrapping" {
    var counter = std.atomic.Value(u64).init(std.math.maxInt(u64) - 1);
    try std.testing.expectEqual(
        std.math.maxInt(u64) - 1,
        try reserveExecutorInstance(&counter),
    );
    try std.testing.expectEqual(std.math.maxInt(u64), counter.load(.monotonic));
    try std.testing.expectError(
        TensorError.OutOfMemory,
        reserveExecutorInstance(&counter),
    );
    try std.testing.expectEqual(std.math.maxInt(u64), counter.load(.monotonic));
}

test "PairNibble adaptive tile selector binds measured and nearest topologies" {
    const expected_g8 = [_]usize{ 256, 32, 32, 64, 64, 64, 256, 256 };
    const expected_g16 = [_]usize{ 256, 64, 64, 128, 128, 128, 256, 256 };
    for (1..9) |participants| {
        try std.testing.expectEqual(
            expected_g8[participants - 1],
            try pairNibbleTileRows(participants, 8),
        );
        try std.testing.expectEqual(
            expected_g16[participants - 1],
            try pairNibbleTileRows(participants, 16),
        );
    }
    for ([_]usize{ 0, 9, std.math.maxInt(usize) }) |participants| {
        try std.testing.expectError(
            TensorError.ShapeMismatch,
            pairNibbleTileRows(participants, 8),
        );
    }
    for ([_]usize{ 0, 7, 32 }) |group_size| {
        try std.testing.expectError(
            TensorError.ShapeMismatch,
            pairNibbleTileRows(4, group_size),
        );
    }
}

test "Pair scratch ledger is exact across every admitted topology" {
    const expected_g8_rows = [_]usize{ 256, 32, 32, 64, 64, 64, 256, 256 };
    const expected_g16_rows = [_]usize{ 256, 64, 64, 128, 128, 128, 256, 256 };
    const expected_g8_bytes = [_]usize{
        2048, 512, 768, 2048, 2560, 3072, 14336, 16384,
    };
    const expected_g16_bytes = [_]usize{
        2048, 1024, 1536, 4096, 5120, 6144, 14336, 16384,
    };

    for (1..9) |participants| {
        const fixed_bytes = participants * 2 * paired_tile_rows * @sizeOf(f32);
        const g8 = try derivePairScratchLedger(participants, .{
            .policy = .model_shaped,
            .producer_groups = .{ .g8 = true },
        });
        try std.testing.expectEqual(participants, g8.participants);
        try std.testing.expectEqual(expected_g8_rows[participants - 1], g8.selected_g8_rows);
        try std.testing.expectEqual(@as(usize, 0), g8.selected_g16_rows);
        try std.testing.expectEqual(expected_g8_rows[participants - 1], g8.capacity_rows);
        try std.testing.expectEqual(g8.capacity_rows, g8.branch_stride_rows);
        try std.testing.expectEqual(2 * g8.capacity_rows, g8.participant_stride_rows);
        try std.testing.expectEqual(
            participants * g8.participant_stride_rows,
            g8.f32_elements,
        );
        try std.testing.expectEqual(expected_g8_bytes[participants - 1], g8.bytes);
        try std.testing.expectEqual(fixed_bytes, g8.fixed_counterfactual_bytes);
        try std.testing.expectEqual(fixed_bytes - g8.bytes, g8.reclaimed_bytes);

        const g16 = try derivePairScratchLedger(participants, .{
            .policy = .model_shaped,
            .producer_groups = .{ .g16 = true },
        });
        try std.testing.expectEqual(@as(usize, 0), g16.selected_g8_rows);
        try std.testing.expectEqual(expected_g16_rows[participants - 1], g16.selected_g16_rows);
        try std.testing.expectEqual(expected_g16_rows[participants - 1], g16.capacity_rows);
        try std.testing.expectEqual(expected_g16_bytes[participants - 1], g16.bytes);
        try std.testing.expectEqual(fixed_bytes - g16.bytes, g16.reclaimed_bytes);

        const mixed = try derivePairScratchLedger(participants, .{
            .policy = .model_shaped,
            .producer_groups = .{ .g8 = true, .g16 = true },
        });
        try std.testing.expectEqual(expected_g8_rows[participants - 1], mixed.selected_g8_rows);
        try std.testing.expectEqual(expected_g16_rows[participants - 1], mixed.selected_g16_rows);
        try std.testing.expectEqual(expected_g16_rows[participants - 1], mixed.capacity_rows);
        try std.testing.expectEqual(expected_g16_bytes[participants - 1], mixed.bytes);
        try std.testing.expectEqual(fixed_bytes - mixed.bytes, mixed.reclaimed_bytes);

        const fixed = try derivePairScratchLedger(participants, .{
            .policy = .fixed_256,
            .producer_groups = .{ .g8 = true, .g16 = true },
        });
        try std.testing.expectEqual(paired_tile_rows, fixed.capacity_rows);
        try std.testing.expectEqual(fixed_bytes, fixed.bytes);
        try std.testing.expectEqual(fixed_bytes, fixed.fixed_counterfactual_bytes);
        try std.testing.expectEqual(@as(usize, 0), fixed.reclaimed_bytes);
    }

    for ([_]usize{ 0, 9, std.math.maxInt(usize) }) |participants| {
        inline for ([_]PairScratchPolicy{ .fixed_256, .model_shaped }) |policy| {
            try std.testing.expectError(
                TensorError.ShapeMismatch,
                derivePairScratchLedger(participants, .{
                    .policy = policy,
                    .producer_groups = .{ .g8 = true },
                }),
            );
        }
    }
    inline for ([_]PairScratchPolicy{ .fixed_256, .model_shaped }) |policy| {
        try std.testing.expectError(
            TensorError.ShapeMismatch,
            derivePairScratchLedger(4, .{ .policy = policy }),
        );
    }
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        derivePairScratchLedger(4, .{
            .policy = .disabled,
            .producer_groups = .{ .g16 = true },
        }),
    );
    const disabled = try derivePairScratchLedger(std.math.maxInt(usize), .{});
    try std.testing.expectEqual(std.math.maxInt(usize), disabled.participants);
    try std.testing.expectEqual(@as(usize, 0), disabled.bytes);
    try std.testing.expectEqual(@as(usize, 0), disabled.f32_elements);
}

test "executor logical ledger matches caller allocator payload" {
    const options: ExecutorOptions = .{
        .greedy_argmax = true,
        .pair_scratch = .{
            .policy = .model_shaped,
            .producer_groups = .{ .g8 = true, .g16 = true },
        },
    };
    const pair = try derivePairScratchLedger(4, options.pair_scratch);
    const ledger = try deriveExecutorLogicalLedger(4, options);
    try std.testing.expectEqual(@as(usize, 4), ledger.participants);
    try std.testing.expectEqual(
        @as(usize, 3 * @sizeOf(std.Thread)),
        ledger.worker_thread_handles_bytes,
    );
    try std.testing.expectEqual(
        @as(usize, 4 * @sizeOf(GreedyArgmaxCandidate)),
        ledger.greedy_argmax_bytes,
    );
    try std.testing.expectEqualDeep(pair, ledger.pair_scratch);
    try std.testing.expectEqual(
        ledger.worker_thread_handles_bytes + ledger.greedy_argmax_bytes +
            pair.bytes,
        ledger.allocation_payload_bytes,
    );
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        deriveExecutorLogicalLedger(0, options),
    );
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        deriveExecutorLogicalLedger(std.math.maxInt(usize), .{}),
    );
}

fn pairScratchAllocationProbe(allocator: std.mem.Allocator) !void {
    var executor: Executor = undefined;
    try executor.initWithOptions(allocator, 2, .{
        .greedy_argmax = true,
        .pair_scratch = .{
            .policy = .model_shaped,
            .producer_groups = .{ .g8 = true, .g16 = true },
        },
    });
    defer executor.deinit();

    const telemetry = executor.pairScratchTelemetry();
    try std.testing.expectEqual(PairScratchPolicy.model_shaped, telemetry.policy);
    try std.testing.expectEqual(@as(usize, 1), telemetry.allocations);
    try std.testing.expectEqual(@as(usize, 64), telemetry.ledger.capacity_rows);
    try std.testing.expectEqual(@as(usize, 1024), telemetry.ledger.bytes);
    try std.testing.expectEqual(@as(usize, 4096), telemetry.ledger.fixed_counterfactual_bytes);
    try std.testing.expectEqual(@as(usize, 3072), telemetry.ledger.reclaimed_bytes);
    try std.testing.expectEqual(@as(u64, 0), telemetry.fixed_dispatches);
    try std.testing.expectEqual(@as(u64, 0), telemetry.model_shaped_dispatches);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(executor.pair_scratch_backing.?.ptr) % 64);
}

test "Pair scratch init releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        pairScratchAllocationProbe,
        .{},
    );
}

test "Pair scratch allocation is aligned exact and participant-private" {
    const participants: usize = 4;
    var executor: Executor = undefined;
    try executor.initWithOptions(std.testing.allocator, participants, .{
        .pair_scratch = .{
            .policy = .model_shaped,
            .producer_groups = .{ .g8 = true, .g16 = true },
        },
    });
    defer executor.deinit();

    const telemetry = executor.pairScratchTelemetry();
    const ledger = telemetry.ledger;
    const backing = executor.pair_scratch_backing.?;
    try std.testing.expectEqual(PairScratchPolicy.model_shaped, telemetry.policy);
    try std.testing.expectEqual(@as(usize, 1), telemetry.allocations);
    try std.testing.expectEqual(@as(usize, 128), ledger.capacity_rows);
    try std.testing.expectEqual(@as(usize, 4096), ledger.bytes);
    try std.testing.expectEqual(@as(usize, 8192), ledger.fixed_counterfactual_bytes);
    try std.testing.expectEqual(@as(usize, 4096), ledger.reclaimed_bytes);
    try std.testing.expectEqual(ledger.f32_elements, backing.len);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(backing.ptr) % 64);

    var previous_end = @intFromPtr(backing.ptr);
    for (0..participants) |participant| {
        const participant_start = participant * ledger.participant_stride_rows;
        const gate = backing[participant_start..][0..ledger.branch_stride_rows];
        const up = backing[participant_start + ledger.branch_stride_rows ..][0..ledger.branch_stride_rows];
        const gate_bytes = std.mem.sliceAsBytes(gate);
        const up_bytes = std.mem.sliceAsBytes(up);
        try std.testing.expectEqual(previous_end, @intFromPtr(gate.ptr));
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(gate.ptr) % 64);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(up.ptr) % 64);
        try std.testing.expect(!byteSlicesOverlap(gate_bytes, up_bytes));
        previous_end = @intFromPtr(up.ptr) + up_bytes.len;
    }
    try std.testing.expectEqual(
        @intFromPtr(backing.ptr) + ledger.bytes,
        previous_end,
    );
}

test "persistent PairNibble M1 matches separate branches across geometry and participants" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    try std.testing.expect(pair_nibble_executor_abi != int4_weights.pair_nibble_abi);

    const allocator = std.testing.allocator;
    // Five shards even at the largest selected tile exercise every measured
    // participant topology, with a four-row tail.
    const out_f: usize = 256 * 4 + 4;
    var input_values: [128]f32 = undefined;
    var q_input: [128]i8 = undefined;
    var activation_scales: [16]f32 = undefined;

    for ([_]usize{ 1, 2, 4, 8 }) |participants| {
        var executor: Executor = undefined;
        try executor.init(allocator, participants);
        defer executor.deinit();

        for ([_]usize{ 8, 16 }) |group_size| {
            const selected_tile = try pairNibbleTileRows(
                participants,
                group_size,
            );
            for ([_]usize{ 16, 64, 80, 128 }) |in_f| {
                var fixture = try PairExecutorTestFixture.init(
                    allocator,
                    out_f,
                    in_f,
                    group_size,
                );
                defer fixture.deinit();
                for (input_values[0..in_f], 0..) |*value, index| {
                    value.* = (@as(f32, @floatFromInt(
                        (index * 17 + group_size + in_f) % 47,
                    )) - 23.0) / 29.0;
                }
                var input = try tensor.fromF32(
                    allocator,
                    &.{ 1, in_f },
                    input_values[0..in_f],
                );
                defer input.deinit();
                var expected_gate = try tensor.zerosF32(
                    allocator,
                    &.{ 1, out_f },
                );
                defer expected_gate.deinit();
                var expected_up = try tensor.zerosF32(
                    allocator,
                    &.{ 1, out_f },
                );
                defer expected_up.deinit();
                var actual_gate = try tensor.zerosF32(
                    allocator,
                    &.{ 1, out_f },
                );
                defer actual_gate.deinit();
                var actual_up = try tensor.zerosF32(
                    allocator,
                    &.{ 1, out_f },
                );
                defer actual_up.deinit();

                const scale_count = int4_matmul.q8ActivationScaleCount(
                    in_f,
                    group_size,
                );
                try int4_matmul.quantizeQ8Activation(
                    input.asF32(),
                    group_size,
                    q_input[0..in_f],
                    activation_scales[0..scale_count],
                );
                try int4_matmul.linearInt4WeightQ8Prepared(
                    q_input[0..in_f],
                    activation_scales[0..scale_count],
                    fixture.gate_weights,
                    fixture.gate_bias,
                    expected_gate,
                    out_f,
                    in_f,
                );
                try int4_matmul.linearInt4WeightQ8Prepared(
                    q_input[0..in_f],
                    activation_scales[0..scale_count],
                    fixture.up_weights,
                    fixture.up_bias,
                    expected_up,
                    out_f,
                    in_f,
                );

                const before = executor.pairNibbleTelemetry();
                try executor.runPairNibble(.{
                    .x = input,
                    .weights = fixture.pair,
                    .gate_bias = fixture.gate_bias,
                    .up_bias = fixture.up_bias,
                    .gate_out = actual_gate,
                    .up_out = actual_up,
                    .out_f = out_f,
                    .in_f = in_f,
                });
                const after = executor.pairNibbleTelemetry();
                try std.testing.expectEqualSlices(
                    u8,
                    std.mem.sliceAsBytes(expected_gate.asF32()),
                    std.mem.sliceAsBytes(actual_gate.asF32()),
                );
                try std.testing.expectEqualSlices(
                    u8,
                    std.mem.sliceAsBytes(expected_up.asF32()),
                    std.mem.sliceAsBytes(actual_up.asF32()),
                );
                try std.testing.expectEqual(before.successful_runs + 1, after.successful_runs);
                try std.testing.expectEqual(
                    before.activation_quantizations + 1,
                    after.activation_quantizations,
                );
                try std.testing.expectEqual(before.m1_runs + 1, after.m1_runs);
                try std.testing.expectEqual(before.m2_runs, after.m2_runs);
                try std.testing.expectEqual(before.m3_runs, after.m3_runs);
                try std.testing.expectEqual(before.m4_runs, after.m4_runs);
                try std.testing.expectEqual(
                    before.projected_rows + out_f,
                    after.projected_rows,
                );
                try std.testing.expectEqual(
                    before.row_shards +
                        (out_f + selected_tile - 1) / selected_tile,
                    after.row_shards,
                );
                try std.testing.expectEqual(
                    @as(u64, selected_tile),
                    after.last_tile_rows,
                );
                try std.testing.expectEqual(
                    @as(u64, (out_f + selected_tile - 1) / selected_tile),
                    after.last_shard_count,
                );
            }
        }
    }
}

test "outputless PairNibble SwiGLU Q8 matches the materialized oracle" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const out_f: usize = 256 * 2 + 4;
    const in_f: usize = 80;
    var input_values: [in_f]f32 = undefined;
    for (&input_values, 0..) |*value, index| {
        value.* = (@as(f32, @floatFromInt((index * 29 + 7) % 61)) - 30.0) /
            37.0;
    }

    for (1..9) |participants| {
        for ([_]usize{ 8, 16 }) |pair_group_size| {
            var executor: Executor = undefined;
            try executor.initWithOptions(allocator, participants, .{
                .pair_scratch = .{
                    .policy = .model_shaped,
                    .producer_groups = .{
                        .g8 = pair_group_size == 8,
                        .g16 = pair_group_size == 16,
                    },
                },
            });
            defer executor.deinit();
            var fixture = try PairExecutorTestFixture.init(
                allocator,
                out_f,
                in_f,
                pair_group_size,
            );
            defer fixture.deinit();
            var input = try tensor.fromF32(
                allocator,
                &.{ 1, in_f },
                &input_values,
            );
            defer input.deinit();
            var gate = try tensor.zerosF32(allocator, &.{ 1, out_f });
            defer gate.deinit();
            var up = try tensor.zerosF32(allocator, &.{ 1, out_f });
            defer up.deinit();

            try executor.runPairNibble(.{
                .x = input,
                .weights = fixture.pair,
                .gate_bias = fixture.gate_bias,
                .up_bias = fixture.up_bias,
                .gate_out = gate,
                .up_out = up,
                .out_f = out_f,
                .in_f = in_f,
            });
            for ([_]u32{ 8, 16 }) |down_group_size| {
                const scale_count = int4_matmul.q8ActivationScaleCount(
                    out_f,
                    down_group_size,
                );
                const expected_q = try allocator.alloc(i8, out_f);
                defer allocator.free(expected_q);
                const actual_q = try allocator.alloc(i8, out_f);
                defer allocator.free(actual_q);
                const expected_scales = try allocator.alloc(f32, scale_count);
                defer allocator.free(expected_scales);
                const actual_scales = try allocator.alloc(f32, scale_count);
                defer allocator.free(actual_scales);
                @memset(actual_q, -91);
                @memset(actual_scales, -91.0);
                try kernels.siluMulQuantizeQ8(
                    gate,
                    up,
                    down_group_size,
                    expected_q,
                    expected_scales,
                );

                const before = executor.pairNibbleTelemetry();
                try executor.runPairNibbleSiluQ8(.{
                    .x = input,
                    .weights = fixture.pair,
                    .gate_bias = fixture.gate_bias,
                    .up_bias = fixture.up_bias,
                    .q_output = actual_q,
                    .activation_scales = actual_scales,
                    .out_f = out_f,
                    .in_f = in_f,
                    .down_group_size = down_group_size,
                });
                const after = executor.pairNibbleTelemetry();
                try std.testing.expectEqualSlices(i8, expected_q, actual_q);
                try std.testing.expectEqualSlices(
                    u8,
                    std.mem.sliceAsBytes(expected_scales),
                    std.mem.sliceAsBytes(actual_scales),
                );
                try std.testing.expectEqual(
                    before.successful_runs + 1,
                    after.successful_runs,
                );
                try std.testing.expectEqual(
                    before.silu_q8_runs + 1,
                    after.silu_q8_runs,
                );
            }
        }
    }
}

test "disabled Pair scratch rejects outputless work and executor reuses" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const out_f: usize = 64;
    const in_f: usize = 32;
    var fixture = try PairExecutorTestFixture.init(allocator, out_f, in_f, 8);
    defer fixture.deinit();
    const input_values = [_]f32{0.25} ** in_f;
    var input = try tensor.fromF32(allocator, &.{ 1, in_f }, &input_values);
    defer input.deinit();
    var q_output = [_]i8{-71} ** out_f;
    var output_scales = [_]f32{-73.0} **
        int4_matmul.q8ActivationScaleCount(out_f, 8);

    var executor: Executor = undefined;
    try executor.init(allocator, 2);
    defer executor.deinit();
    @memset(executor.shared_q8_g8[0..in_f], -75);
    @memset(executor.shared_scales_g8[0..in_f], -77.0);
    const pair_before = executor.pairNibbleTelemetry();
    const scratch_before = executor.pairScratchTelemetry();
    try std.testing.expectEqual(PairScratchPolicy.disabled, scratch_before.policy);
    try std.testing.expectEqual(@as(usize, 0), scratch_before.allocations);
    try std.testing.expectEqual(@as(usize, 0), scratch_before.ledger.bytes);

    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runPairNibbleSiluQ8(.{
            .x = input,
            .weights = fixture.pair,
            .gate_bias = fixture.gate_bias,
            .up_bias = fixture.up_bias,
            .q_output = &q_output,
            .activation_scales = &output_scales,
            .out_f = out_f,
            .in_f = in_f,
            .down_group_size = 8,
        }),
    );
    for (q_output) |value| try std.testing.expectEqual(@as(i8, -71), value);
    for (output_scales) |value|
        try std.testing.expectEqual(@as(f32, -73.0), value);
    for (executor.shared_q8_g8[0..in_f]) |value|
        try std.testing.expectEqual(@as(i8, -75), value);
    for (executor.shared_scales_g8[0..in_f]) |value|
        try std.testing.expectEqual(@as(f32, -77.0), value);
    try std.testing.expectEqualDeep(pair_before, executor.pairNibbleTelemetry());
    try std.testing.expectEqualDeep(scratch_before, executor.pairScratchTelemetry());

    var gate = try tensor.zerosF32(allocator, &.{ 1, out_f });
    defer gate.deinit();
    var up = try tensor.zerosF32(allocator, &.{ 1, out_f });
    defer up.deinit();
    try executor.runPairNibble(.{
        .x = input,
        .weights = fixture.pair,
        .gate_bias = fixture.gate_bias,
        .up_bias = fixture.up_bias,
        .gate_out = gate,
        .up_out = up,
        .out_f = out_f,
        .in_f = in_f,
    });
    try std.testing.expectEqual(pair_before.successful_runs + 1, executor.pairNibbleTelemetry().successful_runs);
    try std.testing.expectEqualDeep(scratch_before, executor.pairScratchTelemetry());
}

test "Pair scratch rejects an unadmitted producer group before private writes" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const participants: usize = 2;
    const out_f: usize = 64;
    const in_f: usize = 32;
    var g8_fixture = try PairExecutorTestFixture.init(allocator, out_f, in_f, 8);
    defer g8_fixture.deinit();
    var g16_fixture = try PairExecutorTestFixture.init(allocator, out_f, in_f, 16);
    defer g16_fixture.deinit();
    const input_values = [_]f32{0.375} ** in_f;
    var input = try tensor.fromF32(allocator, &.{ 1, in_f }, &input_values);
    defer input.deinit();
    var q_output = [_]i8{-91} ** out_f;
    var output_scales = [_]f32{-93.0} **
        int4_matmul.q8ActivationScaleCount(out_f, 8);

    var executor: Executor = undefined;
    try executor.initWithOptions(allocator, participants, .{
        .pair_scratch = .{
            .policy = .model_shaped,
            .producer_groups = .{ .g8 = true },
        },
    });
    defer executor.deinit();
    @memset(executor.shared_q8_g16[0..in_f], -95);
    const input_scale_count = int4_matmul.q8ActivationScaleCount(in_f, 16);
    @memset(executor.shared_scales_g16[0..input_scale_count], -97.0);
    const pair_before = executor.pairNibbleTelemetry();
    const scratch_before = executor.pairScratchTelemetry();
    const scratch_bytes = std.mem.sliceAsBytes(executor.pair_scratch_backing.?);
    const scratch_snapshot = try allocator.dupe(u8, scratch_bytes);
    defer allocator.free(scratch_snapshot);

    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runPairNibbleSiluQ8(.{
            .x = input,
            .weights = g16_fixture.pair,
            .gate_bias = g16_fixture.gate_bias,
            .up_bias = g16_fixture.up_bias,
            .q_output = &q_output,
            .activation_scales = &output_scales,
            .out_f = out_f,
            .in_f = in_f,
            .down_group_size = 8,
        }),
    );
    for (q_output) |value| try std.testing.expectEqual(@as(i8, -91), value);
    for (output_scales) |value|
        try std.testing.expectEqual(@as(f32, -93.0), value);
    for (executor.shared_q8_g16[0..in_f]) |value|
        try std.testing.expectEqual(@as(i8, -95), value);
    for (executor.shared_scales_g16[0..input_scale_count]) |value|
        try std.testing.expectEqual(@as(f32, -97.0), value);
    try std.testing.expectEqualSlices(u8, scratch_snapshot, scratch_bytes);
    try std.testing.expectEqualDeep(pair_before, executor.pairNibbleTelemetry());
    try std.testing.expectEqualDeep(scratch_before, executor.pairScratchTelemetry());

    try executor.runPairNibbleSiluQ8(.{
        .x = input,
        .weights = g8_fixture.pair,
        .gate_bias = g8_fixture.gate_bias,
        .up_bias = g8_fixture.up_bias,
        .q_output = &q_output,
        .activation_scales = &output_scales,
        .out_f = out_f,
        .in_f = in_f,
        .down_group_size = 8,
    });
    try std.testing.expectEqual(
        pair_before.silu_q8_runs + 1,
        executor.pairNibbleTelemetry().silu_q8_runs,
    );
    try std.testing.expectEqual(
        scratch_before.model_shaped_dispatches + 1,
        executor.pairScratchTelemetry().model_shaped_dispatches,
    );
}

test "fixed and model-shaped Pair scratch are bit exact with distinct receipts" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const participants: usize = 4;
    const out_f: usize = 64;
    const in_f: usize = 32;
    const down_group_size: u32 = 16;
    var fixture = try PairExecutorTestFixture.init(allocator, out_f, in_f, 8);
    defer fixture.deinit();
    var input_values: [in_f]f32 = undefined;
    for (&input_values, 0..) |*value, index|
        value.* = (@as(f32, @floatFromInt(index)) - 15.0) / 19.0;
    var input = try tensor.fromF32(allocator, &.{ 1, in_f }, &input_values);
    defer input.deinit();
    var fixed_q = [_]i8{-81} ** out_f;
    var shaped_q = [_]i8{-83} ** out_f;
    var fixed_scales = [_]f32{-85.0} **
        int4_matmul.q8ActivationScaleCount(out_f, down_group_size);
    var shaped_scales = [_]f32{-87.0} ** fixed_scales.len;

    var fixed: Executor = undefined;
    try fixed.initWithOptions(allocator, participants, .{
        .pair_scratch = .{
            .policy = .fixed_256,
            .producer_groups = .{ .g8 = true },
        },
    });
    defer fixed.deinit();
    var shaped: Executor = undefined;
    try shaped.initWithOptions(allocator, participants, .{
        .pair_scratch = .{
            .policy = .model_shaped,
            .producer_groups = .{ .g8 = true },
        },
    });
    defer shaped.deinit();

    try fixed.runPairNibbleSiluQ8(.{
        .x = input,
        .weights = fixture.pair,
        .gate_bias = fixture.gate_bias,
        .up_bias = fixture.up_bias,
        .q_output = &fixed_q,
        .activation_scales = &fixed_scales,
        .out_f = out_f,
        .in_f = in_f,
        .down_group_size = down_group_size,
    });
    try shaped.runPairNibbleSiluQ8(.{
        .x = input,
        .weights = fixture.pair,
        .gate_bias = fixture.gate_bias,
        .up_bias = fixture.up_bias,
        .q_output = &shaped_q,
        .activation_scales = &shaped_scales,
        .out_f = out_f,
        .in_f = in_f,
        .down_group_size = down_group_size,
    });
    try std.testing.expectEqualSlices(i8, &fixed_q, &shaped_q);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(&fixed_scales),
        std.mem.sliceAsBytes(&shaped_scales),
    );

    const fixed_receipt = fixed.pairScratchTelemetry();
    try std.testing.expectEqual(PairScratchPolicy.fixed_256, fixed_receipt.policy);
    try std.testing.expectEqual(@as(usize, 8192), fixed_receipt.ledger.bytes);
    try std.testing.expectEqual(@as(usize, 8192), fixed_receipt.ledger.fixed_counterfactual_bytes);
    try std.testing.expectEqual(@as(usize, 0), fixed_receipt.ledger.reclaimed_bytes);
    try std.testing.expectEqual(@as(u64, 1), fixed_receipt.fixed_dispatches);
    try std.testing.expectEqual(@as(u64, 0), fixed_receipt.model_shaped_dispatches);

    const shaped_receipt = shaped.pairScratchTelemetry();
    try std.testing.expectEqual(PairScratchPolicy.model_shaped, shaped_receipt.policy);
    try std.testing.expectEqual(@as(usize, 2048), shaped_receipt.ledger.bytes);
    try std.testing.expectEqual(@as(usize, 8192), shaped_receipt.ledger.fixed_counterfactual_bytes);
    try std.testing.expectEqual(@as(usize, 6144), shaped_receipt.ledger.reclaimed_bytes);
    try std.testing.expectEqual(@as(u64, 0), shaped_receipt.fixed_dispatches);
    try std.testing.expectEqual(@as(u64, 1), shaped_receipt.model_shaped_dispatches);
}

test "single-epoch PairNibble down matches the two-dispatch oracle" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    // A 16-row producer tail and two 64-row down tiles exercise the composed
    // ownership boundaries without violating the down kernel's K16 contract.
    const hidden: usize = 528;
    const dim: usize = 128;
    var input_values: [dim]f32 = undefined;
    for (&input_values, 0..) |*value, index| {
        value.* = (@as(f32, @floatFromInt((index * 31 + 11) % 67)) - 33.0) /
            41.0;
    }

    for (1..9) |participants| {
        var input = try tensor.fromF32(
            allocator,
            &.{ 1, dim },
            &input_values,
        );
        defer input.deinit();
        for ([_]usize{ 8, 16 }) |pair_group_size| {
            var executor: Executor = undefined;
            try executor.initWithOptions(allocator, participants, .{
                .pair_scratch = .{
                    .policy = .model_shaped,
                    .producer_groups = .{
                        .g8 = pair_group_size == 8,
                        .g16 = pair_group_size == 16,
                    },
                },
            });
            defer executor.deinit();
            var pair_fixture = try PairExecutorTestFixture.init(
                allocator,
                hidden,
                dim,
                pair_group_size,
            );
            defer pair_fixture.deinit();
            for ([_]usize{ 8, 16 }) |down_group_size| {
                var down_fixture = try PairExecutorTestFixture.init(
                    allocator,
                    dim,
                    hidden,
                    down_group_size,
                );
                defer down_fixture.deinit();
                const scale_count = int4_matmul.q8ActivationScaleCount(
                    hidden,
                    down_group_size,
                );
                const expected_q = try allocator.alloc(i8, hidden);
                defer allocator.free(expected_q);
                const actual_q = try allocator.alloc(i8, hidden);
                defer allocator.free(actual_q);
                const expected_scales = try allocator.alloc(f32, scale_count);
                defer allocator.free(expected_scales);
                const actual_scales = try allocator.alloc(f32, scale_count);
                defer allocator.free(actual_scales);
                @memset(actual_q, -87);
                @memset(actual_scales, -89.0);
                var expected_down = try tensor.zerosF32(allocator, &.{ 1, dim });
                defer expected_down.deinit();
                var actual_down = try tensor.zerosF32(allocator, &.{ 1, dim });
                defer actual_down.deinit();

                try executor.runPairNibbleSiluQ8(.{
                    .x = input,
                    .weights = pair_fixture.pair,
                    .gate_bias = pair_fixture.gate_bias,
                    .up_bias = pair_fixture.up_bias,
                    .q_output = expected_q,
                    .activation_scales = expected_scales,
                    .out_f = hidden,
                    .in_f = dim,
                    .down_group_size = @intCast(down_group_size),
                });
                try int4_matmul.linearInt4WeightQ8Prepared(
                    expected_q,
                    expected_scales,
                    down_fixture.gate_weights,
                    down_fixture.gate_bias,
                    expected_down,
                    dim,
                    hidden,
                );

                const producer: PairNibbleSiluQ8Projection = .{
                    .x = input,
                    .weights = pair_fixture.pair,
                    .gate_bias = pair_fixture.gate_bias,
                    .up_bias = pair_fixture.up_bias,
                    .q_output = actual_q,
                    .activation_scales = actual_scales,
                    .out_f = hidden,
                    .in_f = dim,
                    .down_group_size = @intCast(down_group_size),
                };
                const down: PairNibblePreparedDownProjection = .{
                    .weights = down_fixture.gate_weights,
                    .bias = down_fixture.gate_bias,
                    .out = actual_down,
                    .out_f = dim,
                    .in_f = hidden,
                };
                const telemetry_before_rejects = executor.pairNibbleTelemetry();
                const input_snapshot = try allocator.dupe(u8, input.data);
                defer allocator.free(input_snapshot);
                var aliased_down = down;
                aliased_down.out = input;
                try std.testing.expectError(
                    TensorError.ShapeMismatch,
                    executor.runPairNibbleSiluQ8Down(producer, aliased_down),
                );
                try std.testing.expectEqualSlices(u8, input_snapshot, input.data);

                const down_weight_snapshot = try allocator.dupe(
                    u8,
                    down_fixture.gate_packed,
                );
                defer allocator.free(down_weight_snapshot);
                var q_alias_producer = producer;
                q_alias_producer.q_output = std.mem.bytesAsSlice(
                    i8,
                    down_fixture.gate_packed[0..hidden],
                );
                try std.testing.expectError(
                    TensorError.ShapeMismatch,
                    executor.runPairNibbleSiluQ8Down(q_alias_producer, down),
                );
                try std.testing.expectEqualSlices(
                    u8,
                    down_weight_snapshot,
                    down_fixture.gate_packed,
                );

                const down_bias_snapshot = try allocator.dupe(
                    f32,
                    down_fixture.gate_bias,
                );
                defer allocator.free(down_bias_snapshot);
                var scale_alias_producer = producer;
                scale_alias_producer.activation_scales =
                    down_fixture.gate_bias[0..scale_count];
                try std.testing.expectError(
                    TensorError.ShapeMismatch,
                    executor.runPairNibbleSiluQ8Down(scale_alias_producer, down),
                );
                try std.testing.expectEqualSlices(
                    u8,
                    std.mem.sliceAsBytes(down_bias_snapshot),
                    std.mem.sliceAsBytes(down_fixture.gate_bias),
                );

                const pair_weight_snapshot = try allocator.dupe(
                    u8,
                    pair_fixture.paired_bytes,
                );
                defer allocator.free(pair_weight_snapshot);
                var pair_weight_output = actual_down;
                pair_weight_output.data =
                    pair_fixture.paired_bytes[0..actual_down.data.len];
                var pair_alias_down = down;
                pair_alias_down.out = pair_weight_output;
                try std.testing.expectError(
                    TensorError.ShapeMismatch,
                    executor.runPairNibbleSiluQ8Down(producer, pair_alias_down),
                );
                try std.testing.expectEqualSlices(
                    u8,
                    pair_weight_snapshot,
                    pair_fixture.paired_bytes,
                );

                var expanded_marker = [_]i8{0};
                var expanded_down = down;
                expanded_down.weights.expanded_i8 = &expanded_marker;
                try std.testing.expectError(
                    TensorError.ShapeMismatch,
                    executor.runPairNibbleSiluQ8Down(producer, expanded_down),
                );
                for (actual_q) |value|
                    try std.testing.expectEqual(@as(i8, -87), value);
                for (actual_scales) |value|
                    try std.testing.expectEqual(@as(f32, -89.0), value);
                for (actual_down.asF32()) |value|
                    try std.testing.expectEqual(@as(f32, 0.0), value);
                try std.testing.expectEqual(
                    telemetry_before_rejects.silu_q8_runs,
                    executor.pairNibbleTelemetry().silu_q8_runs,
                );

                try executor.runPairNibbleSiluQ8Down(producer, down);
                try std.testing.expectEqualSlices(i8, expected_q, actual_q);
                try std.testing.expectEqualSlices(
                    u8,
                    std.mem.sliceAsBytes(expected_scales),
                    std.mem.sliceAsBytes(actual_scales),
                );
                try std.testing.expectEqualSlices(
                    u8,
                    std.mem.sliceAsBytes(expected_down.asF32()),
                    std.mem.sliceAsBytes(actual_down.asF32()),
                );
                try std.testing.expectEqual(
                    telemetry_before_rejects.silu_q8_runs + 1,
                    executor.pairNibbleTelemetry().silu_q8_runs,
                );
            }
        }
    }
}

fn expectPairNibblePreparedDownRejectNoWrites(
    allocator: std.mem.Allocator,
    executor: *Executor,
    producer: PairNibbleSiluQ8Projection,
    down: PairNibblePreparedDownProjection,
) !void {
    const q_snapshot = try allocator.dupe(
        u8,
        std.mem.sliceAsBytes(producer.q_output),
    );
    defer allocator.free(q_snapshot);
    const scale_snapshot = try allocator.dupe(
        u8,
        std.mem.sliceAsBytes(producer.activation_scales),
    );
    defer allocator.free(scale_snapshot);
    const down_snapshot = try allocator.dupe(u8, down.out.data);
    defer allocator.free(down_snapshot);
    const telemetry_snapshot = executor.pairNibbleTelemetry();

    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runPairNibbleSiluQ8Down(producer, down),
    );
    try std.testing.expectEqualSlices(
        u8,
        q_snapshot,
        std.mem.sliceAsBytes(producer.q_output),
    );
    try std.testing.expectEqualSlices(
        u8,
        scale_snapshot,
        std.mem.sliceAsBytes(producer.activation_scales),
    );
    try std.testing.expectEqualSlices(u8, down_snapshot, down.out.data);
    try std.testing.expectEqualDeep(
        telemetry_snapshot,
        executor.pairNibbleTelemetry(),
    );
}

test "x-less PairNibble down rejects before any caller write" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const hidden: usize = 64;
    const dim: usize = 32;
    const group_size: usize = 8;
    const activation_scale_count: usize = hidden / 32;
    comptime std.debug.assert(
        activation_scale_count ==
            int4_matmul.q8ActivationScaleCount(hidden, group_size),
    );
    const rows4_scale_count = dim * hidden / group_size;

    var pair_fixture = try PairExecutorTestFixture.init(
        allocator,
        hidden,
        dim,
        group_size,
    );
    defer pair_fixture.deinit();
    var down_fixture = try PairExecutorTestFixture.init(
        allocator,
        dim,
        hidden,
        group_size,
    );
    defer down_fixture.deinit();
    const input_values = [_]f32{0.25} ** dim;
    var input = try tensor.fromF32(allocator, &.{ 1, dim }, &input_values);
    defer input.deinit();
    var q_output = [_]i8{-101} ** hidden;
    var activation_scales = [_]f32{-103.0} ** activation_scale_count;
    var down_output = try tensor.zerosF32(allocator, &.{ 1, dim });
    defer down_output.deinit();
    @memset(down_output.asF32(), -107.0);
    var executor: Executor = undefined;
    try executor.initWithOptions(allocator, 4, .{
        .pair_scratch = .{
            .policy = .model_shaped,
            .producer_groups = .{ .g8 = true },
        },
    });
    defer executor.deinit();

    const producer: PairNibbleSiluQ8Projection = .{
        .x = input,
        .weights = pair_fixture.pair,
        .gate_bias = pair_fixture.gate_bias,
        .up_bias = pair_fixture.up_bias,
        .q_output = &q_output,
        .activation_scales = &activation_scales,
        .out_f = hidden,
        .in_f = dim,
        .down_group_size = group_size,
    };
    const down: PairNibblePreparedDownProjection = .{
        .weights = down_fixture.gate_weights,
        .bias = down_fixture.gate_bias,
        .out = down_output,
        .out_f = dim,
        .in_f = hidden,
    };
    const telemetry_snapshot = executor.pairNibbleTelemetry();

    var malformed_shape = [_]usize{ 2, dim / 2 };
    var malformed_output = down;
    malformed_output.out.shape = &malformed_shape;
    try expectPairNibblePreparedDownRejectNoWrites(
        allocator,
        &executor,
        producer,
        malformed_output,
    );

    var short_packed = down;
    short_packed.weights.packed_bytes =
        short_packed.weights.packed_bytes[0 .. short_packed.weights.packed_bytes.len - 1];
    try expectPairNibblePreparedDownRejectNoWrites(
        allocator,
        &executor,
        producer,
        short_packed,
    );

    var short_rows4_scales = down;
    short_rows4_scales.weights.scales_f16_rows4 =
        short_rows4_scales.weights.scales_f16_rows4[0 .. short_rows4_scales.weights.scales_f16_rows4.len - 1];
    try expectPairNibblePreparedDownRejectNoWrites(
        allocator,
        &executor,
        producer,
        short_rows4_scales,
    );

    // Both prepared activation streams must remain disjoint from the rows4
    // scale stream that the down kernel reads after the phase barrier.
    var rows4_alias_storage: [rows4_scale_count * @sizeOf(f16)]u8 align(@alignOf(f32)) =
        [_]u8{0xa5} ** (rows4_scale_count * @sizeOf(f16));
    var rows4_alias_down = down;
    rows4_alias_down.weights.scales_f16_rows4 = std.mem.bytesAsSlice(
        f16,
        rows4_alias_storage[0..],
    );
    var q_rows4_alias = producer;
    q_rows4_alias.q_output = std.mem.bytesAsSlice(
        i8,
        rows4_alias_storage[0..hidden],
    );
    try expectPairNibblePreparedDownRejectNoWrites(
        allocator,
        &executor,
        q_rows4_alias,
        rows4_alias_down,
    );
    for (rows4_alias_storage) |value|
        try std.testing.expectEqual(@as(u8, 0xa5), value);

    var scale_rows4_alias = producer;
    scale_rows4_alias.activation_scales = std.mem.bytesAsSlice(
        f32,
        rows4_alias_storage[0 .. activation_scale_count * @sizeOf(f32)],
    );
    try expectPairNibblePreparedDownRejectNoWrites(
        allocator,
        &executor,
        scale_rows4_alias,
        rows4_alias_down,
    );
    for (rows4_alias_storage) |value|
        try std.testing.expectEqual(@as(u8, 0xa5), value);

    // The complete producer Q/scales are published before down starts, so the
    // down output cannot reuse either slice even though the execution is one
    // worker broadcast.
    var output_q_alias_storage: [dim * @sizeOf(f32)]u8 align(@alignOf(f32)) =
        [_]u8{0xa7} ** (dim * @sizeOf(f32));
    var output_q_alias_producer = producer;
    output_q_alias_producer.q_output = std.mem.bytesAsSlice(
        i8,
        output_q_alias_storage[0..hidden],
    );
    var output_q_alias_down = down;
    output_q_alias_down.out.data = output_q_alias_storage[0..];
    try expectPairNibblePreparedDownRejectNoWrites(
        allocator,
        &executor,
        output_q_alias_producer,
        output_q_alias_down,
    );
    for (output_q_alias_storage) |value|
        try std.testing.expectEqual(@as(u8, 0xa7), value);

    var output_scale_alias_storage: [dim * @sizeOf(f32)]u8 align(@alignOf(f32)) =
        [_]u8{0xa9} ** (dim * @sizeOf(f32));
    var output_scale_alias_producer = producer;
    output_scale_alias_producer.activation_scales = std.mem.bytesAsSlice(
        f32,
        output_scale_alias_storage[0 .. activation_scale_count * @sizeOf(f32)],
    );
    var output_scale_alias_down = down;
    output_scale_alias_down.out.data = output_scale_alias_storage[0..];
    try expectPairNibblePreparedDownRejectNoWrites(
        allocator,
        &executor,
        output_scale_alias_producer,
        output_scale_alias_down,
    );
    for (output_scale_alias_storage) |value|
        try std.testing.expectEqual(@as(u8, 0xa9), value);

    @memset(executor.shared_scales_g8[0..dim], 109.0);
    var executor_alias_down = down;
    executor_alias_down.out.data = std.mem.sliceAsBytes(
        executor.shared_scales_g8[0..dim],
    );
    try expectPairNibblePreparedDownRejectNoWrites(
        allocator,
        &executor,
        producer,
        executor_alias_down,
    );
    for (executor.shared_scales_g8[0..dim]) |value|
        try std.testing.expectEqual(@as(f32, 109.0), value);

    const scratch_bytes = std.mem.sliceAsBytes(executor.pair_scratch_backing.?);
    const scratch_snapshot = try allocator.dupe(u8, scratch_bytes);
    defer allocator.free(scratch_snapshot);
    var scratch_output_down = down;
    scratch_output_down.out.data = scratch_bytes[0..down.out.data.len];
    try expectPairNibblePreparedDownRejectNoWrites(
        allocator,
        &executor,
        producer,
        scratch_output_down,
    );
    var scratch_weight_down = down;
    scratch_weight_down.weights.packed_bytes =
        scratch_bytes[0..down.weights.packed_bytes.len];
    try expectPairNibblePreparedDownRejectNoWrites(
        allocator,
        &executor,
        producer,
        scratch_weight_down,
    );
    try std.testing.expectEqualSlices(u8, scratch_snapshot, scratch_bytes);

    for (q_output) |value| try std.testing.expectEqual(@as(i8, -101), value);
    for (activation_scales) |value|
        try std.testing.expectEqual(@as(f32, -103.0), value);
    for (down_output.asF32()) |value|
        try std.testing.expectEqual(@as(f32, -107.0), value);
    try std.testing.expectEqualDeep(
        telemetry_snapshot,
        executor.pairNibbleTelemetry(),
    );
}

test "single-epoch PairNibble worker failure drains and executor reuses" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const out_f: usize = 64;
    const in_f: usize = 32;
    var fixture = try PairExecutorTestFixture.init(allocator, out_f, in_f, 8);
    defer fixture.deinit();
    var input_q = [_]i8{0} ** in_f;
    var input_scales = [_]f32{1.0} **
        int4_matmul.q8ActivationScaleCount(in_f, 8);
    var q_output = [_]i8{-41} ** out_f;
    var output_scales = [_]f32{-43.0} **
        int4_matmul.q8ActivationScaleCount(out_f, 8);
    const recipe = try int4_matmul.PreparedPairNibbleQ8TilePlan.init(
        fixture.pair,
        fixture.gate_bias,
        fixture.up_bias,
    );
    const bound = try recipe.bind(&input_q, &input_scales);
    var executor: Executor = undefined;
    try executor.initWithOptions(allocator, 4, .{
        .pair_scratch = .{
            .policy = .model_shaped,
            .producer_groups = .{ .g8 = true },
        },
    });
    defer executor.deinit();
    const input_values = [_]f32{0.25} ** in_f;
    var context: PairDownEpochContext = .{
        .producer = .{
            .plan = bound,
            .input = &input_values,
            .input_q = &input_q,
            .input_scales = &input_scales,
            .q_output = &q_output,
            .output_scales = &output_scales,
            .down_group_size = 8,
            .participant_count = executor.participantCount(),
            .shard_count = 1,
            .tile_rows = 0,
            .scratch = executor.pair_scratch_backing.?,
            .scratch_capacity_rows = executor.pair_scratch_ledger.capacity_rows,
            .scratch_participant_stride_rows = executor.pair_scratch_ledger.participant_stride_rows,
        },
        .down = .{ .total_tiles = 0 },
        .barrier = PhaseBarrier.init(executor.participantCount()),
    };
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.parallelFor(
            executor.participantCount(),
            @ptrCast(&context),
            PairDownEpochContext.run,
        ),
    );
    try std.testing.expectEqual(@as(u32, 1), context.barrier.phase.load(.acquire));
    for (q_output) |value| try std.testing.expectEqual(@as(i8, -41), value);
    for (output_scales) |value|
        try std.testing.expectEqual(@as(f32, -43.0), value);

    var input = try tensor.fromF32(
        allocator,
        &.{ 1, in_f },
        &input_values,
    );
    defer input.deinit();
    try executor.runPairNibbleSiluQ8(.{
        .x = input,
        .weights = fixture.pair,
        .gate_bias = fixture.gate_bias,
        .up_bias = fixture.up_bias,
        .q_output = &q_output,
        .activation_scales = &output_scales,
        .out_f = out_f,
        .in_f = in_f,
        .down_group_size = 8,
    });
    try std.testing.expectEqual(@as(u64, 1), executor.pairNibbleTelemetry().silu_q8_runs);
}

test "outputless PairNibble bridge rejects before caller writes" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const out_f: usize = 64;
    const in_f: usize = 32;
    var fixture = try PairExecutorTestFixture.init(allocator, out_f, in_f, 8);
    defer fixture.deinit();
    const input_values = [_]f32{0.25} ** in_f;
    var input = try tensor.fromF32(allocator, &.{ 1, in_f }, &input_values);
    defer input.deinit();
    var q_output = [_]i8{-77} ** out_f;
    var output_scales = [_]f32{-79.0} **
        int4_matmul.q8ActivationScaleCount(out_f, 8);
    var executor: Executor = undefined;
    try executor.initWithOptions(allocator, 4, .{
        .pair_scratch = .{
            .policy = .model_shaped,
            .producer_groups = .{ .g8 = true },
        },
    });
    defer executor.deinit();

    const valid: PairNibbleSiluQ8Projection = .{
        .x = input,
        .weights = fixture.pair,
        .gate_bias = fixture.gate_bias,
        .up_bias = fixture.up_bias,
        .q_output = &q_output,
        .activation_scales = &output_scales,
        .out_f = out_f,
        .in_f = in_f,
        .down_group_size = 8,
    };
    var short = valid;
    short.q_output = q_output[0 .. q_output.len - 1];
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runPairNibbleSiluQ8(short),
    );
    var truncated = valid;
    truncated.weights.paired_bytes =
        truncated.weights.paired_bytes[0 .. truncated.weights.paired_bytes.len - 1];
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runPairNibbleSiluQ8(truncated),
    );

    const input_snapshot = try allocator.dupe(u8, input.data);
    defer allocator.free(input_snapshot);
    var input_alias = valid;
    input_alias.q_output = std.mem.bytesAsSlice(i8, input.data[0..out_f]);
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runPairNibbleSiluQ8(input_alias),
    );
    try std.testing.expectEqualSlices(u8, input_snapshot, input.data);

    const weights_snapshot = try allocator.dupe(u8, fixture.paired_bytes);
    defer allocator.free(weights_snapshot);
    var weights_alias = valid;
    weights_alias.q_output = std.mem.bytesAsSlice(
        i8,
        fixture.paired_bytes[0..out_f],
    );
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runPairNibbleSiluQ8(weights_alias),
    );
    try std.testing.expectEqualSlices(
        u8,
        weights_snapshot,
        fixture.paired_bytes,
    );

    const gate_bias_snapshot = try allocator.dupe(f32, fixture.gate_bias);
    defer allocator.free(gate_bias_snapshot);
    var bias_alias = valid;
    bias_alias.activation_scales = fixture.gate_bias[0..output_scales.len];
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runPairNibbleSiluQ8(bias_alias),
    );
    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(gate_bias_snapshot),
        std.mem.sliceAsBytes(fixture.gate_bias),
    );

    var overlapping_storage: [out_f + @sizeOf(f32) * output_scales.len]u8 align(@alignOf(f32)) =
        [_]u8{0xa5} ** (out_f + @sizeOf(f32) * output_scales.len);
    var mutual_alias = valid;
    mutual_alias.q_output = std.mem.bytesAsSlice(
        i8,
        overlapping_storage[0..out_f],
    );
    const scale_offset = out_f - @sizeOf(f32);
    mutual_alias.activation_scales = std.mem.bytesAsSlice(
        f32,
        overlapping_storage[scale_offset .. scale_offset +
            @sizeOf(f32) * output_scales.len],
    );
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runPairNibbleSiluQ8(mutual_alias),
    );
    for (overlapping_storage) |value|
        try std.testing.expectEqual(@as(u8, 0xa5), value);

    @memset(executor.shared_q8_g8[0..out_f], -37);
    var executor_alias = valid;
    executor_alias.q_output = executor.shared_q8_g8[0..out_f];
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runPairNibbleSiluQ8(executor_alias),
    );
    for (executor.shared_q8_g8[0..out_f]) |value|
        try std.testing.expectEqual(@as(i8, -37), value);

    const scratch_bytes = std.mem.sliceAsBytes(executor.pair_scratch_backing.?);
    const scratch_snapshot = try allocator.dupe(u8, scratch_bytes);
    defer allocator.free(scratch_snapshot);
    var scratch_output_alias = valid;
    scratch_output_alias.q_output = std.mem.bytesAsSlice(
        i8,
        scratch_bytes[0..out_f],
    );
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runPairNibbleSiluQ8(scratch_output_alias),
    );
    var scratch_weight_alias = valid;
    scratch_weight_alias.weights.paired_bytes =
        scratch_bytes[0..fixture.paired_bytes.len];
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runPairNibbleSiluQ8(scratch_weight_alias),
    );
    try std.testing.expectEqualSlices(u8, scratch_snapshot, scratch_bytes);

    for (q_output) |value| try std.testing.expectEqual(@as(i8, -77), value);
    for (output_scales) |value|
        try std.testing.expectEqual(@as(f32, -79.0), value);
    try std.testing.expectEqual(@as(u64, 0), executor.pairNibbleTelemetry().silu_q8_runs);

    try executor.runPairNibbleSiluQ8(valid);
    try std.testing.expectEqual(@as(u64, 1), executor.pairNibbleTelemetry().silu_q8_runs);
}

test "PairNibble coarse shards are claimed exactly once" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const selected_tile = try pairNibbleTileRows(4, 8);
    const out_f = selected_tile * 4 + 4;
    const in_f: usize = 16;
    const shard_count = (out_f + selected_tile - 1) / selected_tile;
    try std.testing.expectEqual(@as(usize, 5), shard_count);
    var fixture = try PairExecutorTestFixture.init(allocator, out_f, in_f, 8);
    defer fixture.deinit();
    var gate = try tensor.zerosF32(allocator, &.{ 1, out_f });
    defer gate.deinit();
    var up = try tensor.zerosF32(allocator, &.{ 1, out_f });
    defer up.deinit();
    const q_input = [_]i8{3} ** in_f;
    const activation_scales = [_]f32{0.125};
    const recipe = try int4_matmul.PreparedPairNibbleQ8Plan.init(
        fixture.pair,
        fixture.gate_bias,
        fixture.up_bias,
        gate.asF32(),
        up.asF32(),
        1,
        out_f,
    );
    const bound = try recipe.bind(&q_input, &activation_scales);
    var visits: [5]std.atomic.Value(u32) = undefined;
    for (&visits) |*visit| visit.* = std.atomic.Value(u32).init(0);
    var batch: PairNibbleBatch = .{
        .plan = bound,
        .shard_count = shard_count,
        .tile_rows = selected_tile,
        .test_shard_visits = &visits,
    };
    var executor: Executor = undefined;
    try executor.init(allocator, 4);
    defer executor.deinit();
    try executor.acquireSubmission();
    defer executor.releaseSubmission();
    try executor.dispatchWork(.{ .pair_nibble = &batch });
    for (&visits) |*visit|
        try std.testing.expectEqual(@as(u32, 1), visit.load(.monotonic));
}

test "PairNibble preflight is no-write and executor is reusable after rejection" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const out_f: usize = 12;
    const in_f: usize = 80;
    var fixture = try PairExecutorTestFixture.init(allocator, out_f, in_f, 8);
    defer fixture.deinit();
    var input_values: [in_f]f32 = undefined;
    for (&input_values, 0..) |*value, index|
        value.* = (@as(f32, @floatFromInt(index % 29)) - 14.0) / 31.0;
    var input = try tensor.fromF32(allocator, &.{ 1, in_f }, &input_values);
    defer input.deinit();
    var gate = try tensor.zerosF32(allocator, &.{ 1, out_f });
    defer gate.deinit();
    var up = try tensor.zerosF32(allocator, &.{ 1, out_f });
    defer up.deinit();
    @memset(gate.asF32(), 73.0);
    @memset(up.asF32(), 79.0);

    var executor: Executor = undefined;
    try executor.init(allocator, 4);
    defer executor.deinit();
    const valid: PairNibbleProjection = .{
        .x = input,
        .weights = fixture.pair,
        .gate_bias = fixture.gate_bias,
        .up_bias = fixture.up_bias,
        .gate_out = gate,
        .up_out = up,
        .out_f = out_f,
        .in_f = in_f,
    };

    var truncated_bytes = valid;
    truncated_bytes.weights.paired_bytes = truncated_bytes.weights.paired_bytes[0 .. truncated_bytes.weights.paired_bytes.len - 1];
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runPairNibble(truncated_bytes),
    );
    var truncated_scales = valid;
    truncated_scales.weights.scales_f16_pairs =
        truncated_scales.weights.scales_f16_pairs[0 .. truncated_scales.weights.scales_f16_pairs.len - 1];
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runPairNibble(truncated_scales),
    );
    var aliased_outputs = valid;
    aliased_outputs.up_out = gate;
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runPairNibble(aliased_outputs),
    );
    for (gate.asF32()) |value| try std.testing.expectEqual(@as(f32, 73.0), value);
    for (up.asF32()) |value| try std.testing.expectEqual(@as(f32, 79.0), value);
    try std.testing.expectEqualDeep(
        PairNibbleTelemetry{
            .successful_runs = 0,
            .activation_quantizations = 0,
            .silu_q8_runs = 0,
            .m1_runs = 0,
            .m2_runs = 0,
            .m3_runs = 0,
            .m4_runs = 0,
            .projected_rows = 0,
            .row_shards = 0,
            .last_tile_rows = 0,
            .last_shard_count = 0,
        },
        executor.pairNibbleTelemetry(),
    );

    // A rejected descriptor cannot poison the submission lease or worker
    // generation. The immediately following valid run must complete normally.
    try executor.runPairNibble(valid);
    const telemetry = executor.pairNibbleTelemetry();
    try std.testing.expectEqual(@as(u64, 1), telemetry.successful_runs);
    try std.testing.expectEqual(@as(u64, 1), telemetry.activation_quantizations);
    try std.testing.expectEqual(@as(u64, 1), telemetry.m1_runs);
    try std.testing.expectEqual(@as(u64, out_f), telemetry.projected_rows);
    try std.testing.expectEqual(
        @as(u64, (out_f + 63) / 64),
        telemetry.row_shards,
    );
    try std.testing.expectEqual(@as(u64, 64), telemetry.last_tile_rows);
    try std.testing.expectEqual(telemetry.row_shards, telemetry.last_shard_count);
}

test "persistent executor runs multiple packed projections without allocations" {
    const allocator = std.testing.allocator;
    const in_f = 16;
    const out_f = 16;
    const element_count = in_f * out_f;
    const packed_bytes = [_]u8{0x77} ** (element_count / 2);
    const scales = [_]f32{1.0} ** (element_count / 8);
    const weights: int4_weights.Int4WeightData = .{
        .packed_bytes = &packed_bytes,
        .scales = &scales,
        .group_size = 8,
        .num_elements = element_count,
    };
    const input_values = [_]f32{1.0} ** in_f;
    var input = try tensor.fromF32(allocator, &.{ 1, in_f }, &input_values);
    defer input.deinit();
    var output_a = try tensor.zerosF32(allocator, &.{ 1, out_f });
    defer output_a.deinit();
    var output_b = try tensor.zerosF32(allocator, &.{ 1, out_f });
    defer output_b.deinit();

    var executor: Executor = undefined;
    try executor.init(allocator, 4);
    defer executor.deinit();
    const projections = [_]Projection{
        .{ .x = input, .weights = weights, .bias = &.{}, .out = output_a, .out_f = out_f, .in_f = in_f, .use_q8 = false },
        .{ .x = input, .weights = weights, .bias = &.{}, .out = output_b, .out_f = out_f, .in_f = in_f, .use_q8 = false },
    };
    try executor.run(&projections);
    for (output_a.asF32()) |value| try std.testing.expectEqual(@as(f32, 0), value);
    try std.testing.expectEqualSlices(f32, output_a.asF32(), output_b.asF32());
}

test "logitless greedy projection matches the materialized rows4 oracle" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const in_f: usize = 16;
    const out_f: usize = greedy_argmax_tile_rows * 2 + 4;
    const winner_row: usize = out_f - 3;
    const element_count = out_f * in_f;
    const packed_count = element_count / 2;
    const input_values = [_]f32{1.0} ** in_f;
    var input = try tensor.fromF32(allocator, &.{ 1, in_f }, &input_values);
    defer input.deinit();
    var output = try tensor.zerosF32(allocator, &.{ 1, out_f });
    defer output.deinit();

    for ([_]u32{ 8, 16 }) |group_size| {
        const scale_count = element_count / group_size;
        const packed_storage = try allocator.alloc(u8, packed_count);
        defer allocator.free(packed_storage);
        @memset(packed_storage, 0x77);
        @memset(
            packed_storage[winner_row * (in_f / 2) ..][0 .. in_f / 2],
            0x88,
        );
        @memset(
            packed_storage[(out_f - 1) * (in_f / 2) ..][0 .. in_f / 2],
            0x88,
        );
        const scales = try allocator.alloc(f32, scale_count);
        defer allocator.free(scales);
        @memset(scales, 1.0);
        var weights: int4_weights.Int4WeightData = .{
            .packed_bytes = packed_storage,
            .scales = scales,
            .group_size = group_size,
            .num_elements = element_count,
        };
        weights = try int4_weights.withRows4F16Scales(
            allocator,
            weights,
            out_f,
        );
        defer allocator.free(weights.scales_f16_rows4);
        weights = try int4_weights.withRows4K16Packing(
            allocator,
            weights,
            out_f,
        );

        for ([_]usize{ 1, 2, 3, 4, 8 }) |participants| {
            var executor: Executor = undefined;
            try executor.initWithOptions(
                allocator,
                participants,
                .{ .greedy_argmax = true },
            );
            defer executor.deinit();
            const projection: Projection = .{
                .x = input,
                .weights = weights,
                .bias = &.{},
                .out = output,
                .out_f = out_f,
                .in_f = in_f,
                .use_q8 = true,
            };
            @memset(output.asF32(), -99);
            try executor.run(&.{projection});
            var oracle_index: usize = 0;
            for (output.asF32()[1..], 1..) |value, index| {
                if (value > output.asF32()[oracle_index]) oracle_index = index;
            }
            try std.testing.expectEqual(winner_row, oracle_index);
            try std.testing.expectEqual(
                oracle_index,
                try executor.runGreedyArgmax(input, weights, out_f, in_f),
            );
            try std.testing.expectEqual(
                oracle_index,
                try executor.runGreedyArgmax(input, weights, out_f, in_f),
            );
            try std.testing.expect(executor.greedyArgmaxScratchBytes() > 0);

            var sparse_words = [_]u64{0} ** 3;
            sparse_words[winner_row / 64] |=
                @as(u64, 1) << @as(u6, @intCast(winner_row % 64));
            sparse_words[(out_f - 1) / 64] |=
                @as(u64, 1) << @as(u6, @intCast((out_f - 1) % 64));
            const sparse = try executor.runGreedyArgmaxEligible(
                input,
                weights,
                out_f,
                in_f,
                &sparse_words,
            );
            try std.testing.expectEqual(winner_row, sparse.token_index);
            try std.testing.expectEqual(@as(usize, 2), sparse.eligible_rows);
            try std.testing.expectEqual(@as(usize, 4), sparse.producer_rows);
            try std.testing.expectEqual(out_f - 4, sparse.skipped_rows);
            try std.testing.expectEqual(@as(usize, 2), sparse.overcomputed_rows);
            try std.testing.expectEqual(@as(usize, 1), sparse.producer_runs);
            try std.testing.expectEqual(
                participants * greedy_argmax_tile_rows * @sizeOf(f32),
                sparse.tile_scratch_bytes,
            );

            var fragmented_words = [_]u64{0} ** 3;
            const fragmented_ids = [_]usize{ 1, 8, 12, 65, 130 };
            for (fragmented_ids) |token_id| {
                fragmented_words[token_id / 64] |=
                    @as(u64, 1) << @as(u6, @intCast(token_id % 64));
            }
            var fragmented_oracle = fragmented_ids[0];
            for (fragmented_ids[1..]) |token_id| {
                const candidate = output.asF32()[token_id];
                const best = output.asF32()[fragmented_oracle];
                if (candidate > best or
                    (candidate == best and token_id < fragmented_oracle))
                    fragmented_oracle = token_id;
            }
            const fragmented = try executor.runGreedyArgmaxEligible(
                input,
                weights,
                out_f,
                in_f,
                &fragmented_words,
            );
            try std.testing.expectEqual(fragmented_oracle, fragmented.token_index);
            try std.testing.expectEqual(fragmented_ids.len, fragmented.eligible_rows);
            try std.testing.expectEqual(@as(usize, 20), fragmented.producer_rows);
            try std.testing.expectEqual(@as(usize, 4), fragmented.producer_runs);

            const full_words = [_]u64{
                std.math.maxInt(u64),
                std.math.maxInt(u64),
                0x0f,
            };
            const full = try executor.runGreedyArgmaxEligible(
                input,
                weights,
                out_f,
                in_f,
                &full_words,
            );
            try std.testing.expectEqual(oracle_index, full.token_index);
            try std.testing.expectEqual(out_f, full.eligible_rows);
            try std.testing.expectEqual(out_f, full.producer_rows);
            try std.testing.expectEqual(@as(usize, 0), full.skipped_rows);
            try std.testing.expectEqual(@as(usize, 0), full.overcomputed_rows);
            try std.testing.expectEqual(@as(usize, 3), full.producer_runs);
        }
    }
}

test "logitless greedy projection is strict and fails before candidate writes" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const in_f: usize = 16;
    const out_f: usize = 4;
    const element_count = out_f * in_f;
    var packed_storage = [_]u8{0x88} ** (element_count / 2);
    const scales = [_]f32{1.0} ** (element_count / 8);
    var weights: int4_weights.Int4WeightData = .{
        .packed_bytes = &packed_storage,
        .scales = &scales,
        .group_size = 8,
        .num_elements = element_count,
    };
    weights = try int4_weights.withRows4F16Scales(allocator, weights, out_f);
    defer allocator.free(weights.scales_f16_rows4);
    weights = try int4_weights.withRows4K16Packing(allocator, weights, out_f);
    var input = try tensor.fromF32(
        allocator,
        &.{ 1, in_f },
        &([_]f32{1.0} ** in_f),
    );
    defer input.deinit();

    var disabled: Executor = undefined;
    try disabled.init(allocator, 1);
    defer disabled.deinit();
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        disabled.runGreedyArgmax(input, weights, out_f, in_f),
    );

    var executor: Executor = undefined;
    try executor.initWithOptions(allocator, 4, .{ .greedy_argmax = true });
    defer executor.deinit();
    const alias_sentinel: GreedyArgmaxCandidate = .{
        .value = 37.0,
        .index = 11,
        .valid = true,
    };
    @memset(executor.greedy_argmax_candidates, alias_sentinel);
    @memset(executor.shared_q8_g8[0..], 17);
    @memset(executor.shared_scales_g8[0..], 23.0);
    for ([_][]const u64{ &.{}, &.{0}, &.{0x10}, &.{ 1, 0 } }) |invalid_mask| {
        try std.testing.expectError(
            TensorError.ShapeMismatch,
            executor.runGreedyArgmaxEligible(
                input,
                weights,
                out_f,
                in_f,
                invalid_mask,
            ),
        );
        for (executor.greedy_argmax_candidates) |candidate|
            try std.testing.expectEqual(alias_sentinel, candidate);
        for (executor.shared_q8_g8) |value|
            try std.testing.expectEqual(@as(i8, 17), value);
        for (executor.shared_scales_g8) |value|
            try std.testing.expectEqual(@as(f32, 23.0), value);
    }
    var aliased_input = input;
    const candidate_bytes = std.mem.sliceAsBytes(
        executor.greedy_argmax_candidates,
    );
    const aliased_eligible_words = std.mem.bytesAsSlice(
        u64,
        candidate_bytes[0..@sizeOf(u64)],
    );
    aliased_eligible_words[0] = 1;
    const aliased_candidate_snapshot = try allocator.dupe(u8, candidate_bytes);
    defer allocator.free(aliased_candidate_snapshot);
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runGreedyArgmaxEligible(
            input,
            weights,
            out_f,
            in_f,
            aliased_eligible_words,
        ),
    );
    try std.testing.expectEqualSlices(
        u8,
        aliased_candidate_snapshot,
        candidate_bytes,
    );
    @memset(executor.greedy_argmax_candidates, alias_sentinel);
    try std.testing.expect(candidate_bytes.len >= input.data.len);
    aliased_input.data = candidate_bytes[0..input.data.len];
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runGreedyArgmax(aliased_input, weights, out_f, in_f),
    );
    for (executor.greedy_argmax_candidates) |candidate|
        try std.testing.expectEqual(alias_sentinel, candidate);

    var truncated = weights;
    truncated.packed_bytes = truncated.packed_bytes[0 .. truncated.packed_bytes.len - 1];
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runGreedyArgmax(input, truncated, out_f, in_f),
    );

    const rows4_scales = @constCast(weights.scales_f16_rows4);
    const saved_scale = rows4_scales[0];
    rows4_scales[0] = @bitCast(@as(u16, 0x7e00));
    defer rows4_scales[0] = saved_scale;
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runGreedyArgmax(input, weights, out_f, in_f),
    );
    const lane_one_only = [_]u64{0b0010};
    const disallowed_nan = try executor.runGreedyArgmaxEligible(
        input,
        weights,
        out_f,
        in_f,
        &lane_one_only,
    );
    try std.testing.expectEqual(@as(usize, 1), disallowed_nan.token_index);
    try std.testing.expectEqual(@as(usize, 1), disallowed_nan.eligible_rows);
    try std.testing.expectEqual(@as(usize, 4), disallowed_nan.producer_rows);
    const lane_zero_only = [_]u64{0b0001};
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runGreedyArgmaxEligible(
            input,
            weights,
            out_f,
            in_f,
            &lane_zero_only,
        ),
    );
    rows4_scales[0] = saved_scale;
    try std.testing.expectEqual(
        @as(usize, 0),
        try executor.runGreedyArgmax(input, weights, out_f, in_f),
    );

    @memset(rows4_scales, std.math.inf(f16));
    try std.testing.expectEqual(
        @as(usize, 0),
        try executor.runGreedyArgmax(input, weights, out_f, in_f),
    );
    @memset(rows4_scales, -std.math.inf(f16));
    try std.testing.expectEqual(
        @as(usize, 0),
        try executor.runGreedyArgmax(input, weights, out_f, in_f),
    );

    // Exercise both the branch-free full-word producer and the partial
    // rows4 materialization/filter path on equal infinities. Every logical
    // weight is +1 here, so infinite scales yield a non-NaN signed infinity
    // and the canonical lowest eligible token ID must win in both paths.
    @memset(&packed_storage, 0x99);
    const all_rows = [_]u64{0b1111};
    const middle_rows = [_]u64{0b0110};
    for ([_]f16{ std.math.inf(f16), -std.math.inf(f16) }) |infinite_scale| {
        @memset(rows4_scales, infinite_scale);
        const full_infinite = try executor.runGreedyArgmaxEligible(
            input,
            weights,
            out_f,
            in_f,
            &all_rows,
        );
        try std.testing.expectEqual(@as(usize, 0), full_infinite.token_index);
        const partial_infinite = try executor.runGreedyArgmaxEligible(
            input,
            weights,
            out_f,
            in_f,
            &middle_rows,
        );
        try std.testing.expectEqual(@as(usize, 1), partial_infinite.token_index);
    }
    @memset(rows4_scales, @as(f16, 1.0));

    const finite_sentinel: GreedyArgmaxCandidate = .{
        .value = 41.0,
        .index = 13,
        .valid = true,
    };
    @memset(executor.greedy_argmax_candidates, finite_sentinel);
    @memset(executor.shared_q8_g8[0..], 17);
    @memset(executor.shared_scales_g8[0..], 23.0);
    input.asF32()[3] = std.math.nan(f32);
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runGreedyArgmax(input, weights, out_f, in_f),
    );
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runGreedyArgmaxEligible(
            input,
            weights,
            out_f,
            in_f,
            &lane_one_only,
        ),
    );
    for (executor.greedy_argmax_candidates) |candidate|
        try std.testing.expectEqual(finite_sentinel, candidate);
    for (executor.shared_q8_g8) |value|
        try std.testing.expectEqual(@as(i8, 17), value);
    for (executor.shared_scales_g8) |value|
        try std.testing.expectEqual(@as(f32, 23.0), value);

    input.asF32()[3] = std.math.inf(f32);
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runGreedyArgmax(input, weights, out_f, in_f),
    );
    input.asF32()[3] = 1.0;
    try std.testing.expectEqual(
        @as(usize, 0),
        try executor.runGreedyArgmax(input, weights, out_f, in_f),
    );
}

test "executor rejects concurrent submissions and remains reusable" {
    const Context = struct {
        entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        err: ?TensorError = null,

        fn blocking(raw_context: *anyopaque, task_index: usize) TensorError!void {
            const self: *@This() = @ptrCast(@alignCast(raw_context));
            if (task_index != 0) return TensorError.ShapeMismatch;
            self.entered.store(true, .release);
            while (!self.release.load(.acquire)) std.atomic.spinLoopHint();
        }

        fn noOp(_: *anyopaque, task_index: usize) TensorError!void {
            if (task_index != 0) return TensorError.ShapeMismatch;
        }

        fn submit(executor: *Executor, self: *@This()) void {
            executor.parallelFor(1, @ptrCast(self), blocking) catch |err| {
                self.err = err;
            };
        }
    };

    var executor: Executor = undefined;
    try executor.init(std.testing.allocator, 1);
    defer executor.deinit();
    var context: Context = .{};
    const thread = try std.Thread.spawn(.{}, Context.submit, .{ &executor, &context });
    while (!context.entered.load(.acquire)) std.atomic.spinLoopHint();
    try std.testing.expectError(
        TensorError.ExecutorBusy,
        executor.parallelFor(1, @ptrCast(&context), Context.noOp),
    );
    context.release.store(true, .release);
    thread.join();
    try std.testing.expect(context.err == null);
    try executor.parallelFor(1, @ptrCast(&context), Context.noOp);
}

test "persistent executor honors the expanded INT8 cache" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const in_f = 16;
    const out_f = 64;
    const element_count = in_f * out_f;
    // The packed stream deliberately represents -7 while the expanded cache
    // represents zero. A zero result proves the executor selected the cache.
    const packed_bytes = [_]u8{0x00} ** (element_count / 2);
    const expanded_i8 = [_]i8{0} ** element_count;
    const scales = [_]f32{1.0} ** (element_count / 8);
    const weights: int4_weights.Int4WeightData = .{
        .packed_bytes = &packed_bytes,
        .scales = &scales,
        .expanded_i8 = &expanded_i8,
        .group_size = 8,
        .num_elements = element_count,
    };
    var input = try tensor.fromF32(
        allocator,
        &.{ 1, in_f },
        &([_]f32{1.0} ** in_f),
    );
    defer input.deinit();
    var output = try tensor.zerosF32(allocator, &.{ 1, out_f });
    defer output.deinit();

    var executor: Executor = undefined;
    try executor.init(allocator, 4);
    defer executor.deinit();
    const projection = Projection{
        .x = input,
        .weights = weights,
        .bias = &.{},
        .out = output,
        .out_f = out_f,
        .in_f = in_f,
        .use_q8 = true,
    };
    try executor.run(&.{projection});
    for (output.asF32()) |value| try std.testing.expectEqual(@as(f32, 0), value);
}

test "persistent executor accepts a caller-prepared Q8 activation" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const in_f = 16;
    const out_f = 64;
    const element_count = in_f * out_f;
    const packed_bytes = [_]u8{0x77} ** (element_count / 2);
    const scales = [_]f32{1.0} ** (element_count / 8);
    const weights: int4_weights.Int4WeightData = .{
        .packed_bytes = &packed_bytes,
        .scales = &scales,
        .group_size = 8,
        .num_elements = element_count,
    };
    var input = try tensor.fromF32(
        allocator,
        &.{ 1, in_f },
        &([_]f32{1.0} ** in_f),
    );
    defer input.deinit();
    var output = try tensor.zerosF32(allocator, &.{ 1, out_f });
    defer output.deinit();

    var executor: Executor = undefined;
    try executor.init(allocator, 4);
    defer executor.deinit();
    const projection: Projection = .{
        .x = input,
        .weights = weights,
        .bias = &.{},
        .out = output,
        .out_f = out_f,
        .in_f = in_f,
        .use_q8 = true,
    };
    const q_input = [_]i8{1} ** in_f;
    const activation_scales = [_]f32{1.0};
    try executor.runPrepared(&.{projection}, &q_input, &activation_scales, 8);
    for (output.asF32()) |value| try std.testing.expectEqual(@as(f32, 0), value);
}

test "prepared activation overrides the expanded-weight input path" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const in_f = 16;
    const out_f = 64;
    const element_count = in_f * out_f;
    const packed_bytes = [_]u8{0x88} ** (element_count / 2);
    const scales = [_]f32{1.0} ** (element_count / 8);
    const expanded_i8 = [_]i8{1} ** element_count;
    const weights: int4_weights.Int4WeightData = .{
        .packed_bytes = &packed_bytes,
        .scales = &scales,
        .expanded_i8 = &expanded_i8,
        .group_size = 8,
        .num_elements = element_count,
    };
    var raw_input = try tensor.fromF32(
        allocator,
        &.{ 1, in_f },
        &([_]f32{0.0} ** in_f),
    );
    defer raw_input.deinit();
    var output = try tensor.zerosF32(allocator, &.{ 1, out_f });
    defer output.deinit();

    var executor: Executor = undefined;
    try executor.init(allocator, 4);
    defer executor.deinit();
    const projection: Projection = .{
        .x = raw_input,
        .weights = weights,
        .bias = &.{},
        .out = output,
        .out_f = out_f,
        .in_f = in_f,
        .use_q8 = true,
    };
    const q_input = [_]i8{1} ** in_f;
    const activation_scales = [_]f32{ 1.0, 1.0 };
    try executor.runPrepared(&.{projection}, &q_input, &activation_scales, 8);
    for (output.asF32()) |value| try std.testing.expectEqual(@as(f32, 16.0), value);
}

test "auto preparation does not override a mixed expanded-weight input" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const in_f = 16;
    const out_f = 64;
    const element_count = in_f * out_f;
    const packed_bytes = [_]u8{0x88} ** (element_count / 2);
    const scales = [_]f32{1.0} ** (element_count / 8);
    const expanded_i8 = [_]i8{1} ** element_count;
    const compact_weights: int4_weights.Int4WeightData = .{
        .packed_bytes = &packed_bytes,
        .scales = &scales,
        .group_size = 8,
        .num_elements = element_count,
    };
    var expanded_weights = compact_weights;
    expanded_weights.expanded_i8 = &expanded_i8;
    var compact_input = try tensor.fromF32(
        allocator,
        &.{ 1, in_f },
        &([_]f32{1.0} ** in_f),
    );
    defer compact_input.deinit();
    var expanded_input = try tensor.fromF32(
        allocator,
        &.{ 1, in_f },
        &([_]f32{2.0} ** in_f),
    );
    defer expanded_input.deinit();
    var compact_output = try tensor.zerosF32(allocator, &.{ 1, out_f });
    defer compact_output.deinit();
    var expanded_output = try tensor.zerosF32(allocator, &.{ 1, out_f });
    defer expanded_output.deinit();

    const projections = [_]Projection{
        .{ .x = compact_input, .weights = compact_weights, .bias = &.{}, .out = compact_output, .out_f = out_f, .in_f = in_f, .use_q8 = true },
        .{ .x = expanded_input, .weights = expanded_weights, .bias = &.{}, .out = expanded_output, .out_f = out_f, .in_f = in_f, .use_q8 = true },
    };
    var executor: Executor = undefined;
    try executor.init(allocator, 4);
    defer executor.deinit();
    try executor.run(&projections);
    for (compact_output.asF32()) |value|
        try std.testing.expectApproxEqAbs(@as(f32, 16.0), value, 0.0001);
    for (expanded_output.asF32()) |value|
        try std.testing.expectApproxEqAbs(@as(f32, 32.0), value, 0.0001);
}

test "persistent executor rejects truncated weight buffers before dispatch" {
    const allocator = std.testing.allocator;
    const in_f = 16;
    const out_f = 16;
    const element_count = in_f * out_f;
    const packed_bytes = [_]u8{0x77} ** (element_count / 2 - 1);
    const scales = [_]f32{1.0} ** (element_count / 8);
    const weights: int4_weights.Int4WeightData = .{
        .packed_bytes = &packed_bytes,
        .scales = &scales,
        .group_size = 8,
        .num_elements = element_count,
    };
    var input = try tensor.fromF32(
        allocator,
        &.{ 1, in_f },
        &([_]f32{1.0} ** in_f),
    );
    defer input.deinit();
    var output = try tensor.zerosF32(allocator, &.{ 1, out_f });
    defer output.deinit();

    var executor: Executor = undefined;
    try executor.init(allocator, 4);
    defer executor.deinit();
    const projection = Projection{
        .x = input,
        .weights = weights,
        .bias = &.{},
        .out = output,
        .out_f = out_f,
        .in_f = in_f,
        .use_q8 = true,
    };
    try std.testing.expectError(TensorError.ShapeMismatch, executor.run(&.{projection}));
}

test "executor rejects output writes into tensor metadata before dispatch" {
    const allocator = std.testing.allocator;
    const in_f: usize = 16;
    const out_f: usize = 4;
    const element_count = in_f * out_f;
    const packed_bytes = [_]u8{0x77} ** (element_count / 2);
    const scales = [_]f32{1.0} ** (element_count / 8);
    const weights: int4_weights.Int4WeightData = .{
        .packed_bytes = &packed_bytes,
        .scales = &scales,
        .group_size = 8,
        .num_elements = element_count,
    };
    var input = try tensor.fromF32(
        allocator,
        &.{ 1, in_f },
        &([_]f32{1.0} ** in_f),
    );
    defer input.deinit();

    // Two usize dimensions occupy exactly the same bytes as four f32 output
    // values on the supported 64-bit targets. A malformed caller must not be
    // allowed to rewrite the descriptor while workers still consume it.
    var output_shape = [2]usize{ 1, out_f };
    const output: Tensor = .{
        .dtype = .f32,
        .shape = &output_shape,
        .data = std.mem.sliceAsBytes(&output_shape),
        .allocator = std.heap.page_allocator,
    };
    const projection: Projection = .{
        .x = input,
        .weights = weights,
        .bias = &.{},
        .out = output,
        .out_f = out_f,
        .in_f = in_f,
        .use_q8 = false,
    };
    var executor: Executor = undefined;
    try executor.init(allocator, 4);
    defer executor.deinit();

    try std.testing.expectError(TensorError.ShapeMismatch, executor.run(&.{projection}));
    try std.testing.expectEqualSlices(usize, &.{ 1, out_f }, &output_shape);

    if (comptime builtin.cpu.arch == .aarch64) {
        var prepared_projection = projection;
        prepared_projection.use_q8 = true;
        const q_input = [_]i8{1} ** in_f;
        const activation_scales = [_]f32{1.0};
        try std.testing.expectError(
            TensorError.ShapeMismatch,
            executor.runPrepared(
                &.{prepared_projection},
                &q_input,
                &activation_scales,
                8,
            ),
        );
        try std.testing.expectEqualSlices(usize, &.{ 1, out_f }, &output_shape);
    }
}

test "executor rejects unsupported tile geometry before any output write" {
    const allocator = std.testing.allocator;
    const in_f: usize = 3;
    const out_f: usize = 65;
    const element_count = in_f * out_f;
    const packed_bytes = [_]u8{0x77} ** ((element_count + 1) / 2);
    const scales = [_]f32{1.0} ** ((element_count + 7) / 8);
    const weights: int4_weights.Int4WeightData = .{
        .packed_bytes = &packed_bytes,
        .scales = &scales,
        .group_size = 8,
        .num_elements = element_count,
    };
    var input = try tensor.fromF32(
        allocator,
        &.{ 1, in_f },
        &([_]f32{1.0} ** in_f),
    );
    defer input.deinit();
    var output = try tensor.fromF32(
        allocator,
        &.{ 1, out_f },
        &([_]f32{9.0} ** out_f),
    );
    defer output.deinit();
    const projection: Projection = .{
        .x = input,
        .weights = weights,
        .bias = &.{},
        .out = output,
        .out_f = out_f,
        .in_f = in_f,
        .use_q8 = false,
    };
    var executor: Executor = undefined;
    try executor.init(allocator, 4);
    defer executor.deinit();

    try std.testing.expectError(TensorError.ShapeMismatch, executor.run(&.{projection}));
    for (output.asF32()) |value|
        try std.testing.expectEqual(@as(f32, 9.0), value);

    // Total weights can be group-aligned while individual rows are not. Q8
    // kernels quantize/dot row-local groups, so accepting this geometry would
    // silently use one scale across a global weight-group boundary.
    const q8_out_f: usize = 8;
    const q8_elements = in_f * q8_out_f;
    const q8_packed = [_]u8{0x77} ** (q8_elements / 2);
    const q8_scales = [_]f32{1.0} ** (q8_elements / 8);
    const q8_weights: int4_weights.Int4WeightData = .{
        .packed_bytes = &q8_packed,
        .scales = &q8_scales,
        .group_size = 8,
        .num_elements = q8_elements,
    };
    var q8_output = try tensor.fromF32(
        allocator,
        &.{ 1, q8_out_f },
        &([_]f32{9.0} ** q8_out_f),
    );
    defer q8_output.deinit();
    const q8_projection: Projection = .{
        .x = input,
        .weights = q8_weights,
        .bias = &.{},
        .out = q8_output,
        .out_f = q8_out_f,
        .in_f = in_f,
        .use_q8 = true,
    };
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.run(&.{q8_projection}),
    );
    for (q8_output.asF32()) |value|
        try std.testing.expectEqual(@as(f32, 9.0), value);
}

test "executor rejects unsupported kernel formats before any output write" {
    const allocator = std.testing.allocator;
    const in_f: usize = 16;
    const out_f: usize = 4;
    const element_count = in_f * out_f;
    const scale_count = element_count / 8;
    const packed_bytes = [_]u8{0x77} ** (element_count / 2);
    const scales = [_]f32{1.0} ** scale_count;
    const half_scales = [_]f16{1.0} ** scale_count;
    var input = try tensor.fromF32(
        allocator,
        &.{ 1, in_f },
        &([_]f32{1.0} ** in_f),
    );
    defer input.deinit();
    var first_output = try tensor.fromF32(
        allocator,
        &.{ 1, out_f },
        &([_]f32{9.0} ** out_f),
    );
    defer first_output.deinit();
    var rejected_output = try tensor.fromF32(
        allocator,
        &.{ 1, out_f },
        &([_]f32{9.0} ** out_f),
    );
    defer rejected_output.deinit();

    const valid_weights: int4_weights.Int4WeightData = .{
        .packed_bytes = &packed_bytes,
        .scales = &scales,
        .group_size = 8,
        .num_elements = element_count,
    };
    const unsupported_rows4: int4_weights.Int4WeightData = .{
        .packed_bytes = &packed_bytes,
        .scales = &scales,
        .scales_f16_rows4 = &half_scales,
        .group_size = 8,
        .num_elements = element_count,
        .packed_layout = .rows4_k16,
    };
    const projections = [_]Projection{
        .{ .x = input, .weights = valid_weights, .bias = &.{}, .out = first_output, .out_f = out_f, .in_f = in_f, .use_q8 = false },
        .{ .x = input, .weights = unsupported_rows4, .bias = &.{}, .out = rejected_output, .out_f = out_f, .in_f = in_f, .use_q8 = false },
    };
    var executor: Executor = undefined;
    try executor.init(allocator, 4);
    defer executor.deinit();

    try std.testing.expectError(TensorError.ShapeMismatch, executor.run(&projections));
    for (first_output.asF32()) |value|
        try std.testing.expectEqual(@as(f32, 9.0), value);
    for (rejected_output.asF32()) |value|
        try std.testing.expectEqual(@as(f32, 9.0), value);

    if (comptime builtin.cpu.arch != .aarch64) {
        const f16_only: int4_weights.Int4WeightData = .{
            .packed_bytes = &packed_bytes,
            .scales = &.{},
            .scales_f16 = &half_scales,
            .group_size = 8,
            .num_elements = element_count,
        };
        var portable_projection = projections[0];
        portable_projection.weights = f16_only;
        portable_projection.use_q8 = true;
        try std.testing.expectError(
            TensorError.ShapeMismatch,
            executor.run(&.{portable_projection}),
        );
        for (first_output.asF32()) |value|
            try std.testing.expectEqual(@as(f32, 9.0), value);
    }
}

test "executor rejects projection storage inside its public state" {
    const allocator = std.testing.allocator;
    const in_f: usize = 16;
    const out_f: usize = @sizeOf(usize) / @sizeOf(f32);
    const element_count = in_f * out_f;
    const packed_bytes = [_]u8{0x77} ** (element_count / 2);
    const scales = [_]f32{1.0} ** (element_count / 8);
    const weights: int4_weights.Int4WeightData = .{
        .packed_bytes = &packed_bytes,
        .scales = &scales,
        .group_size = 8,
        .num_elements = element_count,
    };
    var input = try tensor.fromF32(
        allocator,
        &.{ 1, in_f },
        &([_]f32{1.0} ** in_f),
    );
    defer input.deinit();
    var output_shape = [2]usize{ 1, out_f };
    var executor: Executor = undefined;
    try executor.init(allocator, 4);
    defer executor.deinit();

    const inline_output: Tensor = .{
        .dtype = .f32,
        .shape = &output_shape,
        .data = std.mem.asBytes(&executor.generation),
        .allocator = std.heap.page_allocator,
    };
    const inline_projection: Projection = .{
        .x = input,
        .weights = weights,
        .bias = &.{},
        .out = inline_output,
        .out_f = out_f,
        .in_f = in_f,
        .use_q8 = false,
    };
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.run(&.{inline_projection}),
    );
    try std.testing.expectEqual(@as(usize, 0), executor.generation);

    const thread_bytes = std.mem.sliceAsBytes(executor.threads);
    try std.testing.expect(thread_bytes.len >= out_f * @sizeOf(f32));
    const thread_output: Tensor = .{
        .dtype = .f32,
        .shape = &output_shape,
        .data = thread_bytes[0 .. out_f * @sizeOf(f32)],
        .allocator = std.heap.page_allocator,
    };
    var thread_projection = inline_projection;
    thread_projection.out = thread_output;
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.run(&.{thread_projection}),
    );
    try std.testing.expectEqual(@as(usize, 0), executor.generation);
}

test "persistent executor parallel-for covers every task exactly once" {
    const task_count: usize = 257;
    var visits: [task_count]std.atomic.Value(u32) = undefined;
    for (&visits) |*visit| visit.* = std.atomic.Value(u32).init(0);

    const Context = struct {
        visits: []std.atomic.Value(u32),

        fn run(raw_context: *anyopaque, task_index: usize) TensorError!void {
            const context: *@This() = @ptrCast(@alignCast(raw_context));
            if (task_index >= context.visits.len) return TensorError.ShapeMismatch;
            _ = context.visits[task_index].fetchAdd(1, .monotonic);
        }
    };
    var context: Context = .{ .visits = &visits };
    var executor: Executor = undefined;
    try executor.init(std.testing.allocator, 4);
    defer executor.deinit();

    try std.testing.expectEqual(@as(usize, 4), executor.participantCount());
    try executor.parallelFor(task_count, @ptrCast(&context), Context.run);
    for (&visits) |*visit|
        try std.testing.expectEqual(@as(u32, 1), visit.load(.monotonic));
}

test "persistent executor parallel-for propagates errors and remains reusable" {
    const task_count: usize = 73;
    var visits: [task_count]std.atomic.Value(u32) = undefined;
    for (&visits) |*visit| visit.* = std.atomic.Value(u32).init(0);

    const Context = struct {
        visits: []std.atomic.Value(u32),
        fail_at: ?usize,

        fn run(raw_context: *anyopaque, task_index: usize) TensorError!void {
            const context: *@This() = @ptrCast(@alignCast(raw_context));
            if (context.fail_at == task_index) return TensorError.ShapeMismatch;
            _ = context.visits[task_index].fetchAdd(1, .monotonic);
        }
    };
    var context: Context = .{ .visits = &visits, .fail_at = 19 };
    var executor: Executor = undefined;
    try executor.init(std.testing.allocator, 4);
    defer executor.deinit();

    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.parallelFor(task_count, @ptrCast(&context), Context.run),
    );

    for (&visits) |*visit| visit.* = std.atomic.Value(u32).init(0);
    context.fail_at = null;
    try executor.parallelFor(task_count, @ptrCast(&context), Context.run);
    for (&visits) |*visit|
        try std.testing.expectEqual(@as(u32, 1), visit.load(.monotonic));
}

test "persistent executor parallel-for rejects atomic ticket overflow" {
    const participants: usize = 4;
    const max_safe = std.math.maxInt(usize) - participants;
    try validateParallelTaskCount(max_safe, participants);
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        validateParallelTaskCount(max_safe + 1, participants),
    );

    const Context = struct {
        fn run(_: *anyopaque, _: usize) TensorError!void {}
    };
    var context: u8 = 0;
    var executor: Executor = undefined;
    try executor.init(std.testing.allocator, participants);
    defer executor.deinit();
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.parallelFor(max_safe + 1, @ptrCast(&context), Context.run),
    );
}

test "paired MLP workers steal 256-row g8 and g16 tails exactly once" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    const Verify = struct {
        fn run(
            comptime hidden: usize,
            comptime group_size: u32,
            comptime participants: usize,
        ) !void {
            const allocator = std.testing.allocator;
            const in_f: usize = 16;
            const element_count = hidden * in_f;
            const group_width: usize = group_size;
            const scale_count = element_count / group_width +
                @intFromBool(element_count % group_width != 0);
            const packed_bytes = [_]u8{0x77} ** ((element_count + 1) / 2);
            const weight_scales = [_]f32{1.0} ** scale_count;
            const weights: int4_weights.Int4WeightData = .{
                .packed_bytes = &packed_bytes,
                .scales = &weight_scales,
                .group_size = group_size,
                .num_elements = element_count,
            };

            var input_values: [in_f]f32 = undefined;
            for (&input_values, 0..) |*value, index|
                value.* = @as(f32, @floatFromInt(index + 1)) / 8.0;
            var gate_bias: [hidden]f32 = undefined;
            var up_bias: [hidden]f32 = undefined;
            for (&gate_bias, &up_bias, 0..) |*gate_value, *up_value, index| {
                gate_value.* = (@as(f32, @floatFromInt(index % 29)) - 14.0) / 7.0;
                up_value.* = (@as(f32, @floatFromInt((index * 5) % 31)) - 15.0) / 9.0;
            }

            var input = try tensor.fromF32(allocator, &.{ 1, in_f }, &input_values);
            defer input.deinit();
            var gate = try tensor.zerosF32(allocator, &.{ 1, hidden });
            defer gate.deinit();
            var up = try tensor.zerosF32(allocator, &.{ 1, hidden });
            defer up.deinit();

            const activation_group_size: usize = if (group_size == 8) 32 else 16;
            const activation_scale_count = hidden / activation_group_size +
                @intFromBool(hidden % activation_group_size != 0);
            var q_output: [hidden]i8 = [_]i8{-99} ** hidden;
            var activation_scales: [activation_scale_count]f32 =
                [_]f32{-99} ** activation_scale_count;
            const plan = try kernels.prepareSiluMulQuantizeQ8(
                gate,
                up,
                group_size,
                &q_output,
                &activation_scales,
            );

            const prepared_q = [_]i8{1} ** in_f;
            const prepared_scale_count = int4_matmul.q8ActivationScaleCount(
                in_f,
                group_size,
            );
            const prepared_scales = [_]f32{1.0} ** in_f;
            const projections = [_]Projection{
                .{ .x = input, .weights = weights, .bias = &gate_bias, .out = gate, .out_f = hidden, .in_f = in_f, .use_q8 = true },
                .{ .x = input, .weights = weights, .bias = &up_bias, .out = up, .out_f = hidden, .in_f = in_f, .use_q8 = true },
            };
            const tile_count = (hidden + paired_tile_rows - 1) / paired_tile_rows;
            var tile_visits: [tile_count]std.atomic.Value(u32) = undefined;
            for (&tile_visits) |*visit|
                visit.* = std.atomic.Value(u32).init(0);
            var batch: Batch = .{
                .projections = &projections,
                .total_tiles = tile_count,
                .test_tile_visits = &tile_visits,
            };
            const prepared: PreparedActivation = .{
                .q_input = &prepared_q,
                .scales = prepared_scales[0..prepared_scale_count],
            };
            if (group_size == 8)
                batch.prepared_g8 = prepared
            else
                batch.prepared_g16 = prepared;

            const Context = struct {
                batch: *Batch,
                plan: kernels.SiluMulQuantizeQ8Plan,

                fn runWorker(raw_context: *anyopaque, _: usize) TensorError!void {
                    const self: *@This() = @ptrCast(@alignCast(raw_context));
                    return runPairedProjectionWorker(self.batch, self.plan);
                }
            };
            var context: Context = .{
                .batch = &batch,
                .plan = plan,
            };
            var executor: Executor = undefined;
            try executor.init(allocator, participants);
            defer executor.deinit();
            try executor.parallelFor(
                participants,
                @ptrCast(&context),
                Context.runWorker,
            );
            for (&tile_visits) |*visit|
                try std.testing.expectEqual(@as(u32, 1), visit.load(.monotonic));

            try std.testing.expectEqualSlices(f32, &gate_bias, gate.asF32());
            try std.testing.expectEqualSlices(f32, &up_bias, up.asF32());
            var expected_q: [hidden]i8 = undefined;
            var expected_scales: [activation_scale_count]f32 = undefined;
            try kernels.siluMulQuantizeQ8(
                gate,
                up,
                group_size,
                &expected_q,
                &expected_scales,
            );
            try std.testing.expectEqualSlices(i8, &expected_q, &q_output);
            try std.testing.expectEqualSlices(
                u8,
                std.mem.sliceAsBytes(&expected_scales),
                std.mem.sliceAsBytes(&activation_scales),
            );

            @memset(gate.asF32(), 0);
            @memset(up.asF32(), 0);
            @memset(&q_output, -99);
            @memset(&activation_scales, -99);
            for (&tile_visits) |*visit| visit.store(0, .monotonic);
            batch.next_tile.store(0, .monotonic);
            try executor.parallelFor(
                participants,
                @ptrCast(&context),
                Context.runWorker,
            );
            for (&tile_visits) |*visit|
                try std.testing.expectEqual(@as(u32, 1), visit.load(.monotonic));
            try std.testing.expectEqualSlices(f32, &gate_bias, gate.asF32());
            try std.testing.expectEqualSlices(f32, &up_bias, up.asF32());
            try std.testing.expectEqualSlices(i8, &expected_q, &q_output);
            try std.testing.expectEqualSlices(
                u8,
                std.mem.sliceAsBytes(&expected_scales),
                std.mem.sliceAsBytes(&activation_scales),
            );
        }
    };

    try Verify.run(1, 8, 8);
    try Verify.run(255, 8, 3);
    try Verify.run(256, 8, 4);
    try Verify.run(257, 8, 2);
    try Verify.run(255, 16, 1);
    try Verify.run(256, 16, 4);
    try Verify.run(257, 16, 8);
    try Verify.run(641, 8, 4);
    try Verify.run(643, 16, 4);
}

test "handoff graph orders every phase, propagates errors, and remains reusable" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const width: usize = 16;
    const element_count = width * width;
    const packed_bytes = [_]u8{0x77} ** (element_count / 2);
    const scales = [_]f32{1.0} ** (element_count / 8);
    const weights: int4_weights.Int4WeightData = .{
        .packed_bytes = &packed_bytes,
        .scales = &scales,
        .group_size = 8,
        .num_elements = element_count,
    };
    const input_values = [_]f32{1.0} ** width;
    const bias_one = [_]f32{1.0} ** width;
    const bias_two = [_]f32{2.0} ** width;
    const bias_three = [_]f32{3.0} ** width;
    const bias_four = [_]f32{4.0} ** width;
    var input = try tensor.fromF32(allocator, &.{ 1, width }, &input_values);
    defer input.deinit();
    var q = try tensor.zerosF32(allocator, &.{ 1, width });
    defer q.deinit();
    var k = try tensor.zerosF32(allocator, &.{ 1, width });
    defer k.deinit();
    var v = try tensor.zerosF32(allocator, &.{ 1, width });
    defer v.deinit();
    var attention = try tensor.zerosF32(allocator, &.{ 1, width });
    defer attention.deinit();
    var projection = try tensor.zerosF32(allocator, &.{ 1, width });
    defer projection.deinit();
    var mlp_input = try tensor.zerosF32(allocator, &.{ 1, width });
    defer mlp_input.deinit();
    var gate = try tensor.zerosF32(allocator, &.{ 1, width });
    defer gate.deinit();
    var up = try tensor.zerosF32(allocator, &.{ 1, width });
    defer up.deinit();
    var down = try tensor.zerosF32(allocator, &.{ 1, width });
    defer down.deinit();
    var cache = try kv_cache.KVCache.init(allocator, 1, width, 2);
    defer cache.deinit();

    var visits: [4]std.atomic.Value(u32) = undefined;
    for (&visits) |*visit| visit.* = std.atomic.Value(u32).init(0);
    var final_bridge_visits: [4]std.atomic.Value(u32) = undefined;
    for (&final_bridge_visits) |*visit| visit.* = std.atomic.Value(u32).init(0);
    var q_input: [width]i8 = undefined;
    var activation_scales: [int4_matmul.q8ActivationScaleCount(width, 8)]f32 = undefined;
    const Context = struct {
        q: []const f32,
        k: []const f32,
        v: []const f32,
        attention: []f32,
        projection: []const f32,
        mlp_input: []f32,
        gate: []const f32,
        up: []const f32,
        q_input: []i8,
        activation_scales: []f32,
        visits: []std.atomic.Value(u32),
        final_bridge_visits: []std.atomic.Value(u32),
        cache: *kv_cache.KVCache,
        stage: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        fail_first_bridge: bool = true,
        fail_attention_task: bool = false,
        fail_mlp_bridge: bool = false,
        fail_final_bridge: bool = false,
        fail_parallel_final_bridge: bool = false,

        fn allEqual(values: []const f32, expected: f32) bool {
            for (values) |value| if (value != expected) return false;
            return true;
        }

        fn firstBridge(raw_context: *anyopaque) TensorError!void {
            const self: *@This() = @ptrCast(@alignCast(raw_context));
            if (!allEqual(self.q, 1) or !allEqual(self.k, 1) or !allEqual(self.v, 1))
                return TensorError.ShapeMismatch;
            _ = self.cache.appendRow(0, self.k, self.v) catch
                return TensorError.ShapeMismatch;
            if (self.fail_first_bridge) return TensorError.ShapeMismatch;
            self.stage.store(1, .release);
        }

        fn attentionTask(raw_context: *anyopaque, task_index: usize) TensorError!void {
            const self: *@This() = @ptrCast(@alignCast(raw_context));
            if (self.stage.load(.acquire) != 1 or task_index >= self.visits.len)
                return TensorError.ShapeMismatch;
            if (self.fail_attention_task and task_index == 2)
                return TensorError.ShapeMismatch;
            const lane_width = self.attention.len / self.visits.len;
            @memset(
                self.attention[task_index * lane_width ..][0..lane_width],
                @as(f32, @floatFromInt(task_index + 1)),
            );
            _ = self.visits[task_index].fetchAdd(1, .monotonic);
        }

        fn mlpBridge(raw_context: *anyopaque) TensorError!void {
            const self: *@This() = @ptrCast(@alignCast(raw_context));
            if (self.stage.load(.acquire) != 1 or !allEqual(self.projection, 2))
                return TensorError.ShapeMismatch;
            for (self.visits) |*visit|
                if (visit.load(.monotonic) != 1) return TensorError.ShapeMismatch;
            if (self.fail_mlp_bridge) return TensorError.ShapeMismatch;
            @memset(self.mlp_input, 1);
            self.stage.store(2, .release);
        }

        fn finalBridge(raw_context: *anyopaque) TensorError!void {
            const self: *@This() = @ptrCast(@alignCast(raw_context));
            if (self.stage.load(.acquire) != 2 or
                !allEqual(self.gate, 3) or !allEqual(self.up, 3))
                return TensorError.ShapeMismatch;
            if (self.fail_final_bridge) return TensorError.ShapeMismatch;
            @memset(self.q_input, 1);
            @memset(self.activation_scales, 1);
            self.stage.store(3, .release);
        }

        fn parallelFinalBridge(raw_context: *anyopaque, task_index: usize) TensorError!void {
            const self: *@This() = @ptrCast(@alignCast(raw_context));
            if (self.stage.load(.acquire) != 2 or task_index >= self.final_bridge_visits.len or
                !allEqual(self.gate, 3) or !allEqual(self.up, 3))
                return TensorError.ShapeMismatch;
            if (self.fail_parallel_final_bridge and task_index == 1)
                return TensorError.ShapeMismatch;
            const values_per_task = self.q_input.len / self.final_bridge_visits.len;
            const value_start = task_index * values_per_task;
            const value_end = if (task_index + 1 == self.final_bridge_visits.len)
                self.q_input.len
            else
                value_start + values_per_task;
            @memset(self.q_input[value_start..value_end], 1);
            if (task_index < self.activation_scales.len)
                self.activation_scales[task_index] = 1;
            _ = self.final_bridge_visits[task_index].fetchAdd(1, .monotonic);
        }
    };
    var context: Context = .{
        .q = q.asF32Unsafe(),
        .k = k.asF32Unsafe(),
        .v = v.asF32Unsafe(),
        .attention = attention.asF32Unsafe(),
        .projection = projection.asF32Unsafe(),
        .mlp_input = mlp_input.asF32Unsafe(),
        .gate = gate.asF32Unsafe(),
        .up = up.asF32Unsafe(),
        .q_input = &q_input,
        .activation_scales = &activation_scales,
        .visits = &visits,
        .final_bridge_visits = &final_bridge_visits,
        .cache = &cache,
    };
    const qkv = [_]Projection{
        .{ .x = input, .weights = weights, .bias = &bias_one, .out = q, .out_f = width, .in_f = width, .use_q8 = false },
        .{ .x = input, .weights = weights, .bias = &bias_one, .out = k, .out_f = width, .in_f = width, .use_q8 = false },
        .{ .x = input, .weights = weights, .bias = &bias_one, .out = v, .out_f = width, .in_f = width, .use_q8 = false },
    };
    const output = [_]Projection{
        .{ .x = attention, .weights = weights, .bias = &bias_two, .out = projection, .out_f = width, .in_f = width, .use_q8 = false },
    };
    const mlp = [_]Projection{
        .{ .x = mlp_input, .weights = weights, .bias = &bias_three, .out = gate, .out_f = width, .in_f = width, .use_q8 = true },
        .{ .x = mlp_input, .weights = weights, .bias = &bias_three, .out = up, .out_f = width, .in_f = width, .use_q8 = true },
    };
    const final = [_]Projection{
        .{ .x = gate, .weights = weights, .bias = &bias_four, .out = down, .out_f = width, .in_f = width, .use_q8 = true },
    };
    const graph: HandoffGraph = .{
        .qkv = &qkv,
        .bridge_context = @ptrCast(&context),
        .bridge = Context.firstBridge,
        .attention_context = @ptrCast(&context),
        .attention_task_count = visits.len,
        .attention_task = Context.attentionTask,
        .output = &output,
        .mlp_bridge_context = @ptrCast(&context),
        .mlp_bridge = Context.mlpBridge,
        .mlp = &mlp,
        .final_handoff = .{ .serial = .{
            .context = @ptrCast(&context),
            .task = Context.finalBridge,
        } },
        .final = .{
            .projections = &final,
            .q_input = &q_input,
            .activation_scales = &activation_scales,
            .group_size = 8,
        },
    };

    var executor: Executor = undefined;
    try executor.init(allocator, 4);
    defer executor.deinit();

    const aliased_qkv = [_]Projection{
        .{ .x = input, .weights = weights, .bias = &bias_one, .out = q, .out_f = width, .in_f = width, .use_q8 = false },
        .{ .x = input, .weights = weights, .bias = &bias_one, .out = q, .out_f = width, .in_f = width, .use_q8 = false },
        .{ .x = input, .weights = weights, .bias = &bias_one, .out = v, .out_f = width, .in_f = width, .use_q8 = false },
    };
    var aliased_graph = graph;
    aliased_graph.qkv = &aliased_qkv;
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runHandoffGraph(aliased_graph),
    );
    for (q.asF32()) |value| try std.testing.expectEqual(@as(f32, 0), value);

    try std.testing.expectError(TensorError.ShapeMismatch, executor.runHandoffGraph(graph));
    try std.testing.expectEqual(@as(usize, 0), cache.len);
    try std.testing.expectEqualSlices(f32, k.asF32(), cache.keysSliceCount(0, 1));

    context.fail_first_bridge = false;
    context.fail_attention_task = true;
    context.stage.store(0, .monotonic);
    for (&visits) |*visit| visit.store(0, .monotonic);
    try std.testing.expectError(TensorError.ShapeMismatch, executor.runHandoffGraph(graph));
    try std.testing.expectEqual(@as(u32, 1), context.stage.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), cache.len);

    context.fail_attention_task = false;
    context.fail_mlp_bridge = true;
    context.stage.store(0, .monotonic);
    for (&visits) |*visit| visit.store(0, .monotonic);
    try std.testing.expectError(TensorError.ShapeMismatch, executor.runHandoffGraph(graph));
    try std.testing.expectEqual(@as(u32, 1), context.stage.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), cache.len);

    context.fail_mlp_bridge = false;
    context.fail_final_bridge = true;
    context.stage.store(0, .monotonic);
    for (&visits) |*visit| visit.store(0, .monotonic);
    try std.testing.expectError(TensorError.ShapeMismatch, executor.runHandoffGraph(graph));
    try std.testing.expectEqual(@as(u32, 2), context.stage.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), cache.len);

    context.fail_final_bridge = false;
    context.stage.store(0, .monotonic);
    for (&visits) |*visit| visit.store(0, .monotonic);
    try executor.runHandoffGraph(graph);
    try std.testing.expectEqual(@as(u32, 3), context.stage.load(.acquire));
    for (&visits) |*visit|
        try std.testing.expectEqual(@as(u32, 1), visit.load(.monotonic));
    for (down.asF32()) |value| try std.testing.expectEqual(@as(f32, 4), value);
    try std.testing.expectEqual(@as(usize, 0), cache.len);

    var paired_graph = graph;
    paired_graph.final_handoff = .{ .paired_silu_q8 = .{
        .gate = gate,
        .up = up,
        .q_output = &q_input,
        .activation_scales = &activation_scales,
    } };
    @memset(q.asF32(), 0);
    @memset(k.asF32(), 0);
    @memset(v.asF32(), 0);
    context.stage.store(0, .monotonic);

    var mismatched_bridge = paired_graph;
    mismatched_bridge.final_handoff = .{ .paired_silu_q8 = .{
        .gate = up,
        .up = gate,
        .q_output = &q_input,
        .activation_scales = &activation_scales,
    } };
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runHandoffGraph(mismatched_bridge),
    );

    var short_q_graph = paired_graph;
    short_q_graph.final.q_input = q_input[0 .. q_input.len - 1];
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runHandoffGraph(short_q_graph),
    );

    var short_scales_graph = paired_graph;
    short_scales_graph.final.activation_scales = activation_scales[0..0];
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runHandoffGraph(short_scales_graph),
    );

    const shifted_q_alias = std.mem.bytesAsSlice(i8, mlp_input.data[1..])[0..width];
    var aliased_paired_graph = paired_graph;
    aliased_paired_graph.final.q_input = shifted_q_alias;
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runHandoffGraph(aliased_paired_graph),
    );

    var mismatched_mlp = mlp;
    mismatched_mlp[1].x = input;
    var mismatched_mlp_graph = paired_graph;
    mismatched_mlp_graph.mlp = &mismatched_mlp;
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runHandoffGraph(mismatched_mlp_graph),
    );

    var mismatched_group_mlp = mlp;
    mismatched_group_mlp[1].weights.group_size = 16;
    var mismatched_group_graph = paired_graph;
    mismatched_group_graph.mlp = &mismatched_group_mlp;
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runHandoffGraph(mismatched_group_graph),
    );

    @memset(executor.shared_q8_g8[0..width], -37);
    var scratch_q_graph = paired_graph;
    scratch_q_graph.final.q_input = executor.shared_q8_g8[0..width];
    scratch_q_graph.final_handoff = .{ .paired_silu_q8 = .{
        .gate = gate,
        .up = up,
        .q_output = executor.shared_q8_g8[0..width],
        .activation_scales = &activation_scales,
    } };
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runHandoffGraph(scratch_q_graph),
    );
    for (executor.shared_q8_g8[0..width]) |value|
        try std.testing.expectEqual(@as(i8, -37), value);

    @memset(executor.shared_scales_g8[0..width], 6.0);
    var scratch_input = mlp_input;
    scratch_input.data = std.mem.sliceAsBytes(executor.shared_scales_g8[0..width]);
    var scratch_mlp = mlp;
    scratch_mlp[0].x = scratch_input;
    scratch_mlp[1].x = scratch_input;
    var scratch_graph = paired_graph;
    scratch_graph.mlp = &scratch_mlp;
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runHandoffGraph(scratch_graph),
    );
    for (executor.shared_scales_g8[0..width]) |value|
        try std.testing.expectEqual(@as(f32, 6.0), value);

    var persistent_bias = [_]f32{4.0} ** width;
    var alias_gate = gate;
    alias_gate.data = std.mem.sliceAsBytes(&persistent_bias);
    var persistent_alias_mlp = mlp;
    persistent_alias_mlp[0].out = alias_gate;
    var persistent_alias_final = final;
    persistent_alias_final[0].bias = &persistent_bias;
    var persistent_alias_graph = paired_graph;
    persistent_alias_graph.mlp = &persistent_alias_mlp;
    persistent_alias_graph.final.projections = &persistent_alias_final;
    persistent_alias_graph.final_handoff = .{ .paired_silu_q8 = .{
        .gate = alias_gate,
        .up = up,
        .q_output = &q_input,
        .activation_scales = &activation_scales,
    } };
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runHandoffGraph(persistent_alias_graph),
    );
    try std.testing.expectEqualSlices(
        f32,
        &([_]f32{4.0} ** width),
        &persistent_bias,
    );

    var truncated_input = input;
    truncated_input.data = truncated_input.data[0 .. truncated_input.data.len - @sizeOf(f32)];
    var truncated_qkv = qkv;
    truncated_qkv[0].x = truncated_input;
    var truncated_graph = paired_graph;
    truncated_graph.qkv = &truncated_qkv;
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runHandoffGraph(truncated_graph),
    );
    for (q.asF32()) |value| try std.testing.expectEqual(@as(f32, 0), value);
    for (k.asF32()) |value| try std.testing.expectEqual(@as(f32, 0), value);
    for (v.asF32()) |value| try std.testing.expectEqual(@as(f32, 0), value);
    try std.testing.expectEqual(@as(u32, 0), context.stage.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), cache.len);

    context.stage.store(0, .monotonic);
    @memset(&q_input, 0);
    @memset(&activation_scales, 0);
    for (&visits) |*visit| visit.store(0, .monotonic);
    try executor.runHandoffGraph(paired_graph);
    try std.testing.expectEqual(@as(u32, 2), context.stage.load(.acquire));
    for (down.asF32()) |value| try std.testing.expectEqual(@as(f32, 4), value);
    try std.testing.expectEqual(@as(usize, 0), cache.len);

    var parallel_graph = graph;
    parallel_graph.final_handoff = .{ .parallel = .{
        .context = @ptrCast(&context),
        .task_count = final_bridge_visits.len,
        .task = Context.parallelFinalBridge,
    } };
    context.fail_parallel_final_bridge = true;
    context.stage.store(0, .monotonic);
    @memset(&q_input, 0);
    @memset(&activation_scales, 0);
    for (&visits) |*visit| visit.store(0, .monotonic);
    for (&final_bridge_visits) |*visit| visit.store(0, .monotonic);
    try std.testing.expectError(TensorError.ShapeMismatch, executor.runHandoffGraph(parallel_graph));
    try std.testing.expectEqual(@as(u32, 2), context.stage.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), cache.len);

    context.fail_parallel_final_bridge = false;
    context.stage.store(0, .monotonic);
    @memset(&q_input, 0);
    @memset(&activation_scales, 0);
    for (&visits) |*visit| visit.store(0, .monotonic);
    for (&final_bridge_visits) |*visit| visit.store(0, .monotonic);
    try executor.runHandoffGraph(parallel_graph);
    for (&visits) |*visit|
        try std.testing.expectEqual(@as(u32, 1), visit.load(.monotonic));
    for (&final_bridge_visits) |*visit|
        try std.testing.expectEqual(@as(u32, 1), visit.load(.monotonic));
    for (down.asF32()) |value| try std.testing.expectEqual(@as(f32, 4), value);
    try std.testing.expectEqual(@as(usize, 0), cache.len);
    cache.commit();
    try std.testing.expectEqual(@as(usize, 1), cache.len);
}

test "sealed handoff plan matches checked graph and rejects stale bindings" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const width: usize = 16;
    const element_count = width * width;
    // Non-zero quantized weights make this a numerical graph differential,
    // not merely a bias/barrier-ordering test.
    const row_major_packed = [_]u8{0x88} ** (element_count / 2);
    const scales = [_]f32{1.0} ** (element_count / 8);
    const base_weights: int4_weights.Int4WeightData = .{
        .packed_bytes = &row_major_packed,
        .scales = &scales,
        .group_size = 8,
        .num_elements = element_count,
    };
    const rows4_scales = try int4_weights.withRows4F16Scales(
        allocator,
        base_weights,
        width,
    );
    defer allocator.free(rows4_scales.scales_f16_rows4);
    const packed_owned = try allocator.dupe(u8, row_major_packed[0..]);
    defer allocator.free(packed_owned);
    var packable = rows4_scales;
    packable.packed_bytes = packed_owned;
    const weights = try int4_weights.withRows4K16Packing(
        allocator,
        packable,
        width,
    );

    const input_values = [_]f32{1.0} ** width;
    const bias_one = [_]f32{1.0} ** width;
    const bias_two = [_]f32{2.0} ** width;
    const bias_three = [_]f32{3.0} ** width;
    const bias_four = [_]f32{4.0} ** width;
    var input = try tensor.fromF32(allocator, &.{ 1, width }, &input_values);
    defer input.deinit();
    var q = try tensor.zerosF32(allocator, &.{ 1, width });
    defer q.deinit();
    var k = try tensor.zerosF32(allocator, &.{ 1, width });
    defer k.deinit();
    var v = try tensor.zerosF32(allocator, &.{ 1, width });
    defer v.deinit();
    var attention = try tensor.zerosF32(allocator, &.{ 1, width });
    defer attention.deinit();
    var projection = try tensor.zerosF32(allocator, &.{ 1, width });
    defer projection.deinit();
    var mlp_input = try tensor.zerosF32(allocator, &.{ 1, width });
    defer mlp_input.deinit();
    var gate = try tensor.zerosF32(allocator, &.{ 1, width });
    defer gate.deinit();
    var up = try tensor.zerosF32(allocator, &.{ 1, width });
    defer up.deinit();
    var down = try tensor.zerosF32(allocator, &.{ 1, width });
    defer down.deinit();
    var q_input: [width]i8 = undefined;
    var activation_scales: [int4_matmul.q8ActivationScaleCount(width, 8)]f32 = undefined;
    var visits: [4]std.atomic.Value(u32) = undefined;
    for (&visits) |*visit| visit.* = std.atomic.Value(u32).init(0);

    const Context = struct {
        q: []const f32,
        k: []const f32,
        v: []const f32,
        attention: []f32,
        projection: []const f32,
        mlp_input: []f32,
        visits: []std.atomic.Value(u32),
        stage: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        fn allEqual(values: []const f32, expected: f32) bool {
            for (values) |value| if (value != expected) return false;
            return true;
        }

        fn bridge(raw_context: *anyopaque) TensorError!void {
            const self: *@This() = @ptrCast(@alignCast(raw_context));
            if (!allEqual(self.q, 17) or !allEqual(self.k, 17) or
                !allEqual(self.v, 17))
                return TensorError.ShapeMismatch;
            self.stage.store(1, .release);
        }

        fn attentionTask(raw_context: *anyopaque, task_index: usize) TensorError!void {
            const self: *@This() = @ptrCast(@alignCast(raw_context));
            if (self.stage.load(.acquire) != 1 or task_index >= self.visits.len)
                return TensorError.ShapeMismatch;
            const start = task_index * (self.attention.len / self.visits.len);
            const end = if (task_index + 1 == self.visits.len)
                self.attention.len
            else
                start + self.attention.len / self.visits.len;
            @memset(self.attention[start..end], 1);
            _ = self.visits[task_index].fetchAdd(1, .monotonic);
        }

        fn mlpBridge(raw_context: *anyopaque) TensorError!void {
            const self: *@This() = @ptrCast(@alignCast(raw_context));
            if (self.stage.load(.acquire) != 1 or
                !allEqual(self.projection, 18))
                return TensorError.ShapeMismatch;
            for (self.visits) |*visit|
                if (visit.load(.monotonic) != 1) return TensorError.ShapeMismatch;
            @memset(self.mlp_input, 1);
            self.stage.store(2, .release);
        }

        fn sealedBinding(
            raw_bridge: *anyopaque,
            raw_attention: *anyopaque,
            raw_mlp: *anyopaque,
            layer_index: usize,
            position: usize,
            task_count: usize,
        ) TensorError!u64 {
            _ = layer_index;
            _ = position;
            if (raw_bridge != raw_attention or raw_bridge != raw_mlp)
                return TensorError.ShapeMismatch;
            const self: *@This() = @ptrCast(@alignCast(raw_bridge));
            if (task_count != self.visits.len) return TensorError.ShapeMismatch;
            var key: u64 = 0xcbf2_9ce4_8422_2325;
            key = sealMix(key, pointerBits(self.q.ptr));
            key = sealMix(key, pointerBits(self.k.ptr));
            key = sealMix(key, pointerBits(self.v.ptr));
            key = sealMix(key, pointerBits(self.attention.ptr));
            key = sealMix(key, pointerBits(self.projection.ptr));
            return sealMix(key, pointerBits(self.mlp_input.ptr));
        }
    };
    var context: Context = .{
        .q = q.asF32Unsafe(),
        .k = k.asF32Unsafe(),
        .v = v.asF32Unsafe(),
        .attention = attention.asF32Unsafe(),
        .projection = projection.asF32Unsafe(),
        .mlp_input = mlp_input.asF32Unsafe(),
        .visits = &visits,
    };
    const qkv = [_]Projection{
        .{ .x = input, .weights = weights, .bias = &bias_one, .out = q, .out_f = width, .in_f = width, .use_q8 = true },
        .{ .x = input, .weights = weights, .bias = &bias_one, .out = k, .out_f = width, .in_f = width, .use_q8 = true },
        .{ .x = input, .weights = weights, .bias = &bias_one, .out = v, .out_f = width, .in_f = width, .use_q8 = true },
    };
    const output = [_]Projection{
        .{ .x = attention, .weights = weights, .bias = &bias_two, .out = projection, .out_f = width, .in_f = width, .use_q8 = true },
    };
    const mlp = [_]Projection{
        .{ .x = mlp_input, .weights = weights, .bias = &bias_three, .out = gate, .out_f = width, .in_f = width, .use_q8 = true },
        .{ .x = mlp_input, .weights = weights, .bias = &bias_three, .out = up, .out_f = width, .in_f = width, .use_q8 = true },
    };
    const final = [_]Projection{
        .{ .x = gate, .weights = weights, .bias = &bias_four, .out = down, .out_f = width, .in_f = width, .use_q8 = true },
    };
    const graph: HandoffGraph = .{
        .qkv = &qkv,
        .bridge_context = @ptrCast(&context),
        .bridge = Context.bridge,
        .attention_context = @ptrCast(&context),
        .attention_task_count = visits.len,
        .attention_task = Context.attentionTask,
        .output = &output,
        .mlp_bridge_context = @ptrCast(&context),
        .mlp_bridge = Context.mlpBridge,
        .mlp = &mlp,
        .final_handoff = .{ .paired_silu_q8 = .{
            .gate = gate,
            .up = up,
            .q_output = &q_input,
            .activation_scales = &activation_scales,
        } },
        .final = .{
            .projections = &final,
            .q_input = &q_input,
            .activation_scales = &activation_scales,
            .group_size = 8,
        },
        .sealed_position = 11,
        .sealed_binding = Context.sealedBinding,
    };

    var executor: Executor = undefined;
    try executor.init(allocator, visits.len);
    defer executor.deinit();
    try executor.runHandoffGraph(graph);
    const checked_down = down.asF32()[0..width].*;
    for (checked_down) |value| try std.testing.expect(value > 4);

    var plan = try executor.prepareSealedHandoffPlan(7, graph);
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runSealedHandoffGraph(&plan, .{
            .layer_index = 7,
            .position = 11,
            .bridge_context = @ptrCast(&context),
            .attention_context = @ptrCast(&context),
            .attention_task_count = visits.len,
            .mlp_bridge_context = @ptrCast(&context),
        }),
    );
    try executor.finalizeSealedHandoffPlan(&plan);
    @memset(q.asF32(), -9);
    @memset(k.asF32(), -9);
    @memset(v.asF32(), -9);
    @memset(down.asF32(), -9);
    context.stage.store(0, .monotonic);
    for (&visits) |*visit| visit.store(0, .monotonic);
    try executor.runSealedHandoffGraph(&plan, .{
        .layer_index = 7,
        .position = 11,
        .bridge_context = @ptrCast(&context),
        .attention_context = @ptrCast(&context),
        .attention_task_count = visits.len,
        .mlp_bridge_context = @ptrCast(&context),
    });
    try std.testing.expectEqualSlices(f32, &checked_down, down.asF32());
    try std.testing.expectEqual(@as(u32, 2), context.stage.load(.acquire));

    @memset(q.asF32(), -41);
    plan.qkv_tiles +%= 1;
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runSealedHandoffGraph(&plan, .{
            .layer_index = 7,
            .position = 11,
            .bridge_context = @ptrCast(&context),
            .attention_context = @ptrCast(&context),
            .attention_task_count = visits.len,
            .mlp_bridge_context = @ptrCast(&context),
        }),
    );
    for (q.asF32()) |value| try std.testing.expectEqual(@as(f32, -41), value);
    plan.qkv_tiles -%= 1;

    @memset(q.asF32(), -37);
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runSealedHandoffGraph(&plan, .{
            .layer_index = 8,
            .position = 11,
            .bridge_context = @ptrCast(&context),
            .attention_context = @ptrCast(&context),
            .attention_task_count = visits.len,
            .mlp_bridge_context = @ptrCast(&context),
        }),
    );
    for (q.asF32()) |value| try std.testing.expectEqual(@as(f32, -37), value);

    var other_executor: Executor = undefined;
    try other_executor.init(allocator, visits.len);
    defer other_executor.deinit();
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        other_executor.runSealedHandoffGraph(&plan, .{
            .layer_index = 7,
            .position = 11,
            .bridge_context = @ptrCast(&context),
            .attention_context = @ptrCast(&context),
            .attention_task_count = visits.len,
            .mlp_bridge_context = @ptrCast(&context),
        }),
    );
    for (q.asF32()) |value| try std.testing.expectEqual(@as(f32, -37), value);

    var corrupt_plan = try executor.prepareSealedHandoffPlan(7, graph);
    corrupt_plan.qkv_tiles +%= 1;
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.finalizeSealedHandoffPlan(&corrupt_plan),
    );

    var self_aliased_plan = try executor.prepareSealedHandoffPlan(7, graph);
    self_aliased_plan.qkv[0].plan.recipe.output = @ptrCast(&self_aliased_plan);
    self_aliased_plan.integrity = sealedPlanIntegrity(&self_aliased_plan);
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.finalizeSealedHandoffPlan(&self_aliased_plan),
    );

    var moved_plan = plan;
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runSealedHandoffGraph(&moved_plan, .{
            .layer_index = 7,
            .position = 11,
            .bridge_context = @ptrCast(&context),
            .attention_context = @ptrCast(&context),
            .attention_task_count = visits.len,
            .mlp_bridge_context = @ptrCast(&context),
        }),
    );

    var rebound_context = context;
    rebound_context.q = attention.asF32Unsafe();
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runSealedHandoffGraph(&plan, .{
            .layer_index = 7,
            .position = 11,
            .bridge_context = @ptrCast(&rebound_context),
            .attention_context = @ptrCast(&rebound_context),
            .attention_task_count = visits.len,
            .mlp_bridge_context = @ptrCast(&rebound_context),
        }),
    );

    var lifecycle_executor: Executor = undefined;
    try lifecycle_executor.init(allocator, visits.len);
    var stale_plan = try lifecycle_executor.prepareSealedHandoffPlan(7, graph);
    try lifecycle_executor.finalizeSealedHandoffPlan(&stale_plan);
    lifecycle_executor.deinit();
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        lifecycle_executor.runSealedHandoffGraph(&stale_plan, .{
            .layer_index = 7,
            .position = 11,
            .bridge_context = @ptrCast(&context),
            .attention_context = @ptrCast(&context),
            .attention_task_count = visits.len,
            .mlp_bridge_context = @ptrCast(&context),
        }),
    );
    try lifecycle_executor.init(allocator, visits.len);
    defer lifecycle_executor.deinit();
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        lifecycle_executor.runSealedHandoffGraph(&stale_plan, .{
            .layer_index = 7,
            .position = 11,
            .bridge_context = @ptrCast(&context),
            .attention_context = @ptrCast(&context),
            .attention_task_count = visits.len,
            .mlp_bridge_context = @ptrCast(&context),
        }),
    );

    plan.abi +%= 1;
    try std.testing.expectError(
        TensorError.ShapeMismatch,
        executor.runSealedHandoffGraph(&plan, .{
            .layer_index = 7,
            .position = 11,
            .bridge_context = @ptrCast(&context),
            .attention_context = @ptrCast(&context),
            .attention_task_count = visits.len,
            .mlp_bridge_context = @ptrCast(&context),
        }),
    );
}
