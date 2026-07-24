//! Persistent, transactionally published text generation for one exact
//! prepared-image profile.
//!
//! V1 deliberately admits only prepared `.glrt`, serial CPU execution,
//! separate MLP storage, materialized logits, and deterministic greedy
//! selection. The narrow profile keeps its claim and numerical oracle exact
//! while the broader runtime contract evolves.

const std = @import("std");
const core = @import("core");
const resource_bank = core.resource_bank;
const lane = core.lane_weave_qos;
const tensor = core.tensor;
const forward = @import("forward.zig");
const loader = @import("loader.zig");
const kv = @import("kv_cache.zig");
const decode_buffers = @import("decode_buffers.zig");
const generate = @import("generate.zig");
const sampling = @import("sampling.zig");
const runtime_image = @import("model/runtime_image.zig");
const lane_contiguous = @import("lane_contiguous_publication.zig");
const publication = @import("lane_publication_txn.zig");
const kernels = @import("backends/cpu/kernels.zig");

pub const plan_abi: u64 = 0x474c_5450_0000_0001;
pub const session_abi: u64 = 0x474c_5453_0000_0001;

const prompt_domain = "glacier-prepared-text-prompt-v1\x00";
const plan_domain = "glacier-prepared-text-plan-v1\x00";
const boundary_domain = "glacier-prepared-text-boundary-v1\x00";

pub const Error = error{
    PreparedImageRequired,
    InvalidConfiguration,
    InvalidPlan,
    InvalidAdmission,
    AdmissionClaimMismatch,
    InvalidState,
    RecoveryRequired,
};

pub const OptionsV1 = struct {
    max_new_tokens: usize,
    eos_token: u32 = std.math.maxInt(u32),
    seed: u64 = 0,

    /// Exact legacy configuration used as the numerical compatibility oracle.
    pub fn generateOptions(self: OptionsV1) generate.GenerateOptions {
        return .{
            .max_new_tokens = self.max_new_tokens,
            .eos_token = self.eos_token,
            .sampler = .{ .temperature = 0 },
            .seed = self.seed,
            .num_threads = 1,
            .use_persistent_executor = false,
            .mlp_representation = .separate,
            .decode_frame_mode = .materialized_required,
            .parallel_attention_min_context = null,
            .decode_plan_mode = .checked,
            .greedy_output_mode = .materialized,
            .use_batch_prefill = false,
        };
    }
};

pub const PlanV1 = struct {
    abi_version: u64 = plan_abi,
    image_identity: runtime_image.ImageIdentityV1,
    prompt_tokens: u64,
    prompt_sha256: [32]u8,
    max_new_tokens: u64,
    eos_token: u32,
    seed: u64,
    claim: resource_bank.Claim,
    plan_sha256: [32]u8,
};

pub const BoundarySnapshotV1 = struct {
    abi_version: u64 = session_abi,
    plan_sha256: [32]u8,
    image_identity: runtime_image.ImageIdentityV1,
    publication: publication.TranscriptSnapshotV1,
    boundary_sha256: [32]u8,
};

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

fn promptSha256(prompt: []const u32) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(prompt_domain);
    hashU64(&hash, @intCast(prompt.len));
    for (prompt) |token| hashU32(&hash, token);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn planSha256(plan: PlanV1) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(plan_domain);
    hashU64(&hash, plan.abi_version);
    hash.update(&plan.image_identity.source_fingerprint);
    hash.update(&plan.image_identity.abi_fingerprint);
    hashU64(&hash, plan.image_identity.container_bytes);
    hash.update(&plan.image_identity.container_sha256);
    hashU64(&hash, plan.prompt_tokens);
    hash.update(&plan.prompt_sha256);
    hashU64(&hash, plan.max_new_tokens);
    hashU32(&hash, plan.eos_token);
    hashU64(&hash, plan.seed);
    inline for (std.meta.fields(resource_bank.Claim)) |field| {
        hashU64(&hash, @field(plan.claim, field.name));
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

pub fn boundaryRootV1(snapshot: BoundarySnapshotV1) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(boundary_domain);
    hashU64(&hash, snapshot.abi_version);
    hash.update(&snapshot.plan_sha256);
    hash.update(&snapshot.image_identity.source_fingerprint);
    hash.update(&snapshot.image_identity.abi_fingerprint);
    hashU64(&hash, snapshot.image_identity.container_bytes);
    hash.update(&snapshot.image_identity.container_sha256);
    hashU64(&hash, snapshot.publication.abi_version);
    hashU64(&hash, snapshot.publication.request_epoch);
    hashU64(&hash, snapshot.publication.execution_abi);
    hashU64(&hash, snapshot.publication.next_sequence);
    hashU64(
        &hash,
        snapshot.publication.last_resource_permit_generation,
    );
    hash.update(&[_]u8{@intFromBool(snapshot.publication.terminal)});
    hash.update(&snapshot.publication.state.commitment_sha256);
    hash.update(&snapshot.publication.transcript_sha256);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

pub fn boundarySnapshotValidV1(snapshot: BoundarySnapshotV1) bool {
    if (snapshot.abi_version != session_abi or
        snapshot.image_identity.container_bytes == 0 or
        isZeroDigest(snapshot.plan_sha256) or
        isZeroDigest(snapshot.image_identity.source_fingerprint) or
        isZeroDigest(snapshot.image_identity.abi_fingerprint) or
        isZeroDigest(snapshot.image_identity.container_sha256) or
        snapshot.publication.abi_version !=
            publication.transcript_snapshot_abi or
        snapshot.publication.request_epoch == 0 or
        snapshot.publication.execution_abi != lane_contiguous.abi or
        snapshot.publication.state.execution_abi != lane_contiguous.abi or
        !publication.stateCommitmentValidV1(snapshot.publication.state) or
        snapshot.publication.next_sequence !=
            snapshot.publication.state.output_length or
        isZeroDigest(snapshot.publication.transcript_sha256))
        return false;
    const expected = boundaryRootV1(snapshot);
    return std.mem.eql(
        u8,
        &snapshot.boundary_sha256,
        &expected,
    );
}

fn isZeroDigest(digest: [32]u8) bool {
    return std.mem.allEqual(u8, &digest, 0);
}

pub fn makePlanV1(
    model: loader.LoadedModel,
    prompt: []const u32,
    options: OptionsV1,
) (generate.GenerateError || Error)!PlanV1 {
    if (options.max_new_tokens == 0)
        return Error.InvalidConfiguration;
    // V1 retires only after the admission's fixed service count is exhausted.
    // Early EOS therefore remains outside this exact lifecycle contract.
    if (options.eos_token < model.config.vocab_size)
        return Error.InvalidConfiguration;
    if (model.prepared_mlp_layout != .separate)
        return Error.InvalidConfiguration;
    const image = model.prepared_image orelse
        return Error.PreparedImageRequired;
    const image_identity = image.identityV1();
    if (isZeroDigest(image_identity.source_fingerprint) or
        !std.mem.eql(
            u8,
            &image_identity.source_fingerprint,
            &model.source_fingerprint,
        )) return Error.InvalidConfiguration;

    const max_new_tokens = std.math.cast(
        u64,
        options.max_new_tokens,
    ) orelse return generate.GenerateError.ContextTooLong;
    var claim = try generate.deriveResourceClaim(
        model,
        prompt,
        options.generateOptions(),
    );
    claim.output_journal_bytes = std.math.mul(
        u64,
        max_new_tokens,
        @sizeOf(u32),
    ) catch return generate.GenerateError.ContextTooLong;
    var plan: PlanV1 = .{
        .image_identity = image_identity,
        .prompt_tokens = @intCast(prompt.len),
        .prompt_sha256 = promptSha256(prompt),
        .max_new_tokens = max_new_tokens,
        .eos_token = options.eos_token,
        .seed = options.seed,
        .claim = claim,
        .plan_sha256 = undefined,
    };
    plan.plan_sha256 = planSha256(plan);
    return plan;
}

fn validateAdmissionForAdoption(
    scheduler: *lane.Scheduler,
    bank: *resource_bank.Bank,
    admission: lane.Admission,
    plan: PlanV1,
    request_epoch: u64,
) (Error || lane.Error)!void {
    if (request_epoch == 0 or scheduler.bank != bank)
        return Error.InvalidAdmission;
    const snapshot = try scheduler.snapshot();
    const event = admission.event;
    if (snapshot.closed or snapshot.poisoned or
        event.abi_version != lane.event_abi or
        event.kind != .admission_accepted or
        event.rejection_reason != .none or
        event.scheduler_epoch != snapshot.scheduler_epoch or
        event.event_sequence == std.math.maxInt(u64) or
        event.event_sequence + 1 != snapshot.next_event_sequence or
        !std.meta.eql(admission.handle, event.handle) or
        !std.meta.eql(plan.claim, event.spec.claim) or
        !std.meta.eql(plan.claim, event.resource_receipt.claim) or
        event.spec.work_quanta != plan.max_new_tokens or
        event.remaining_after != plan.max_new_tokens)
        return Error.InvalidAdmission;
    const expected_receipt = lane.resourceReceiptSha256(
        event.resource_receipt,
    );
    const expected_event = lane.eventSha256(event);
    if (!std.mem.eql(
        u8,
        &event.resource_receipt_sha256,
        &expected_receipt,
    ) or
        !std.mem.eql(u8, &event.event_sha256, &expected_event) or
        !std.mem.eql(
            u8,
            &event.event_sha256,
            &snapshot.chain_head_sha256,
        ))
        return Error.InvalidAdmission;
    bank.validateCommitted(event.resource_receipt) catch
        return Error.InvalidAdmission;
}

const Resources = struct {
    allocator: std.mem.Allocator,
    cache: kv.KVCache,
    output: []u32,
    x_row: tensor.Tensor,
    logits: tensor.Tensor,
    buffers: decode_buffers.DecodeBuffers,
    rope_table: generate.PreparedTextRopeTableV1,

    fn init(
        allocator: std.mem.Allocator,
        model: loader.LoadedModel,
        max_kv_positions: usize,
        max_new_tokens: usize,
    ) generate.GenerateError!Resources {
        const cfg = model.config;
        const kv_dim = std.math.mul(
            usize,
            cfg.num_kv_heads,
            cfg.head_dim,
        ) catch return generate.GenerateError.ShapeMismatch;
        var cache = kv.KVCache.init(
            allocator,
            cfg.num_layers,
            kv_dim,
            max_kv_positions,
        ) catch return generate.GenerateError.OutOfMemory;
        errdefer cache.deinit();
        const output = allocator.alloc(u32, max_new_tokens) catch
            return generate.GenerateError.OutOfMemory;
        errdefer allocator.free(output);
        var x_row = tensor.zerosF32(
            allocator,
            &.{ 1, cfg.dim },
        ) catch return generate.GenerateError.OutOfMemory;
        errdefer x_row.deinit();
        var logits = tensor.zerosF32(
            allocator,
            &.{ 1, cfg.vocab_size },
        ) catch return generate.GenerateError.OutOfMemory;
        errdefer logits.deinit();
        var buffers = decode_buffers.DecodeBuffers.initWithFrame(
            allocator,
            cfg.num_layers,
            cfg.dim,
            kv_dim,
            cfg.hidden_dim,
            .materialized,
        ) catch return generate.GenerateError.OutOfMemory;
        errdefer buffers.deinit();
        var rope_table = generate.PreparedTextRopeTableV1.init(
            allocator,
            max_kv_positions,
            cfg.head_dim,
            cfg.rope_theta,
        ) catch return generate.GenerateError.OutOfMemory;
        errdefer rope_table.deinit();
        return .{
            .allocator = allocator,
            .cache = cache,
            .output = output,
            .x_row = x_row,
            .logits = logits,
            .buffers = buffers,
            .rope_table = rope_table,
        };
    }

    fn deinit(self: *Resources) void {
        self.rope_table.deinit();
        self.buffers.deinit();
        self.logits.deinit();
        self.x_row.deinit();
        self.allocator.free(self.output);
        self.cache.deinit();
    }
};

/// Address-stable persistent session. Place it at its final address before
/// calling `init`; the concrete publication adapter binds its field addresses.
pub const SessionV1 = struct {
    model: *const loader.LoadedModel = undefined,
    scheduler: *lane.Scheduler = undefined,
    plan: PlanV1 = undefined,
    options: OptionsV1 = undefined,
    resources: Resources = undefined,
    publication_session: lane_contiguous.Session = .{},
    output_len: usize = 0,
    rng_state: lane_contiguous.RngState = [_]u64{0} ** 4,
    sampling_calls: u64 = 0,
    resources_initialized: bool = false,
    publication_bound: bool = false,
    finished: bool = false,

    /// Adopt the exact just-admitted request. From `Scheduler.admit` through
    /// this call's return, the caller must not make another public call on the
    /// same Scheduler, including from another thread. This preserves the
    /// Scheduler's admission-event-to-publication-binding boundary and makes
    /// failure cleanup unambiguous. Normal shared Scheduler use may resume
    /// after this call succeeds.
    pub fn init(
        self: *SessionV1,
        allocator: std.mem.Allocator,
        model: *const loader.LoadedModel,
        prompt: []const u32,
        options: OptionsV1,
        plan: PlanV1,
        scheduler: *lane.Scheduler,
        bank: *resource_bank.Bank,
        admission: lane.Admission,
        request_epoch: u64,
    ) !void {
        if (self.resources_initialized or self.publication_bound)
            return Error.InvalidState;
        const expected = try makePlanV1(model.*, prompt, options);
        if (!std.meta.eql(expected, plan))
            return Error.InvalidPlan;
        if (!std.meta.eql(plan.claim, admission.event.spec.claim))
            return Error.AdmissionClaimMismatch;
        try validateAdmissionForAdoption(
            scheduler,
            bank,
            admission,
            plan,
            request_epoch,
        );
        var admission_adopted = true;
        errdefer if (admission_adopted) {
            _ = scheduler.cancel(admission.handle) catch
                @panic("prepared text admission cleanup failed");
        };

        const max_kv_positions = std.math.add(
            usize,
            prompt.len,
            options.max_new_tokens - 1,
        ) catch return generate.GenerateError.ContextTooLong;
        const resources = try Resources.init(
            allocator,
            model.*,
            max_kv_positions,
            options.max_new_tokens,
        );
        const initial_prng = std.Random.DefaultPrng.init(options.seed);
        self.* = .{
            .model = model,
            .scheduler = scheduler,
            .plan = plan,
            .options = options,
            .resources = resources,
            .rng_state = initial_prng.s,
            .resources_initialized = true,
        };
        errdefer {
            self.resources.deinit();
            self.* = .{};
        }

        try self.prefill(prompt);
        try self.publication_session.init(
            scheduler,
            bank,
            admission,
            request_epoch,
            .{
                .cache = &self.resources.cache,
                .rng_state = &self.rng_state,
                .sampling_calls = &self.sampling_calls,
                .output = self.resources.output,
                .output_len = &self.output_len,
            },
        );
        self.publication_bound = true;
        admission_adopted = false;
    }

    pub fn deinit(self: *SessionV1) void {
        if (!self.resources_initialized) return;
        if (self.publication_bound) {
            self.publication_session.close() catch
                @panic("prepared text session failed to close");
            self.publication_bound = false;
        }
        self.resources.deinit();
        self.* = .{};
    }

    pub fn step(
        self: *SessionV1,
        permit: lane.ServicePermitV1,
        downstream: publication.SinkV1,
    ) !publication.CommitReceiptV1 {
        if (!self.publication_bound or self.finished)
            return Error.InvalidState;

        const stage = self.prepareStage() catch |err| {
            self.scheduler.abortService(permit) catch
                return Error.RecoveryRequired;
            return err;
        };
        const receipt = try self.publication_session.publish(
            permit,
            stage,
            downstream,
        );
        self.finished = stage.terminal;
        return receipt;
    }

    /// Prepare all fallible numerical state before publication adopts the
    /// service permit. On failure, `step` aborts that still-pending permit;
    /// after success the contiguous publication transaction owns both the
    /// permit and any staged KV row.
    fn prepareStage(self: *SessionV1) !lane_contiguous.StageV1 {
        var mark: ?kv.RowTxnMark = null;
        if (self.output_len != 0) {
            const active_mark = try self.resources.cache.beginRows(1);
            mark = active_mark;
            errdefer self.resources.cache.abortRows(active_mark) catch {};
            try self.decodeCommittedTail(active_mark);
        }
        const sampled = try self.sampleCurrentLogits();
        const terminal = sampled.token_id == self.options.eos_token or
            self.output_len + 1 == self.options.max_new_tokens;
        return .{
            .kv_mark = mark,
            .rng_after = sampled.rng_after,
            .sampling_calls_after = sampled.sampling_calls_after,
            .token_id = sampled.token_id,
            .terminal = terminal,
        };
    }

    pub fn outputTokens(self: *const SessionV1) []const u32 {
        if (!self.resources_initialized) return &.{};
        return self.resources.output[0..self.output_len];
    }

    pub fn isFinished(self: *const SessionV1) bool {
        return self.finished;
    }

    pub fn snapshotVerified(self: *SessionV1) !BoundarySnapshotV1 {
        if (!self.publication_bound) return Error.InvalidState;
        var snapshot: BoundarySnapshotV1 = .{
            .plan_sha256 = self.plan.plan_sha256,
            .image_identity = self.plan.image_identity,
            .publication = try self.publication_session.snapshotVerified(),
            .boundary_sha256 = [_]u8{0} ** 32,
        };
        snapshot.boundary_sha256 = boundaryRootV1(snapshot);
        if (!boundarySnapshotValidV1(snapshot))
            return Error.InvalidState;
        return snapshot;
    }

    pub fn retire(self: *SessionV1) !lane.EventV1 {
        if (!self.publication_bound or !self.finished)
            return Error.InvalidState;
        const event = try self.publication_session.retire();
        self.publication_bound = false;
        return event;
    }

    pub fn cancel(self: *SessionV1) !lane.EventV1 {
        if (!self.publication_bound or self.finished)
            return Error.InvalidState;
        const event = try self.publication_session.cancel();
        self.publication_bound = false;
        return event;
    }

    const SampledToken = struct {
        token_id: u32,
        rng_after: lane_contiguous.RngState,
        sampling_calls_after: u64,
    };

    fn sampleCurrentLogits(self: *SessionV1) !SampledToken {
        if (self.resources.logits.asF32Unsafe().len == 0)
            return Error.InvalidState;
        var prng: std.Random.DefaultPrng = .{ .s = self.rng_state };
        var empty_scratch: [0]sampling.Candidate = .{};
        const token_index = sampling.sample(
            self.resources.logits.asF32Unsafe(),
            .{ .temperature = 0 },
            prng.random(),
            &empty_scratch,
        );
        const token_id = std.math.cast(u32, token_index) orelse
            return generate.GenerateError.ShapeMismatch;
        const calls_after = std.math.add(
            u64,
            self.sampling_calls,
            1,
        ) catch return Error.InvalidState;
        return .{
            .token_id = token_id,
            .rng_after = prng.s,
            .sampling_calls_after = calls_after,
        };
    }

    fn prefill(self: *SessionV1, prompt: []const u32) !void {
        const cfg = self.model.config;
        const layer_cfg = layerConfig(cfg);
        var s_next: [2]usize = undefined;
        var s_final: [2]usize = undefined;
        for (prompt, 0..) |prompt_token, prompt_pos| {
            try generate.loadPreparedTextEmbeddingV1(
                self.model.*,
                prompt_token,
                self.resources.x_row.asF32Unsafe(),
            );
            for (self.model.layers, 0..) |weights, layer_index| {
                const layer_buffers =
                    self.resources.buffers.forLayer(layer_index);
                const next_h = decode_buffers.DecodeBuffers.view(
                    layer_buffers.next_h,
                    &s_next,
                    cfg.dim,
                );
                try forwardOne(
                    layer_cfg,
                    weights,
                    self.resources.x_row,
                    &self.resources.cache,
                    layer_index,
                    prompt_pos,
                    layer_buffers,
                    next_h,
                    &self.resources.rope_table,
                    .prefill,
                    null,
                );
                @memcpy(
                    self.resources.x_row.asF32Unsafe(),
                    layer_buffers.next_h,
                );
            }
            self.resources.cache.commit();
        }
        try self.projectFinal(&s_final);
    }

    fn decodeCommittedTail(self: *SessionV1, mark: kv.RowTxnMark) !void {
        const cfg = self.model.config;
        const previous_token = self.resources.output[self.output_len - 1];
        try generate.loadPreparedTextEmbeddingV1(
            self.model.*,
            previous_token,
            self.resources.x_row.asF32Unsafe(),
        );
        var s_next: [2]usize = undefined;
        var s_final: [2]usize = undefined;
        const cur_pos = self.resources.cache.len;
        const layer_cfg = layerConfig(cfg);
        for (self.model.layers, 0..) |weights, layer_index| {
            const layer_buffers =
                self.resources.buffers.forLayer(layer_index);
            const next_h = decode_buffers.DecodeBuffers.view(
                layer_buffers.next_h,
                &s_next,
                cfg.dim,
            );
            try forwardOne(
                layer_cfg,
                weights,
                self.resources.x_row,
                &self.resources.cache,
                layer_index,
                cur_pos,
                layer_buffers,
                next_h,
                &self.resources.rope_table,
                .decode,
                mark,
            );
            @memcpy(
                self.resources.x_row.asF32Unsafe(),
                layer_buffers.next_h,
            );
        }
        try self.projectFinal(&s_final);
    }

    fn projectFinal(self: *SessionV1, shape: *[2]usize) !void {
        const cfg = self.model.config;
        const last_layer = cfg.num_layers - 1;
        const final_h = decode_buffers.DecodeBuffers.view(
            self.resources.buffers.forLayer(last_layer).next_h,
            shape,
            cfg.dim,
        );
        kernels.rmsNormF32(
            self.resources.x_row,
            self.model.final_norm,
            cfg.rms_eps,
            final_h,
        ) catch return generate.GenerateError.ForwardFailed;
        try generate.projectPreparedTextHeadV1(
            self.model.*,
            final_h,
            self.resources.logits,
        );
    }
};

fn layerConfig(cfg: loader.ModelConfig) forward.LayerConfig {
    return .{
        .dim = cfg.dim,
        .hidden_dim = cfg.hidden_dim,
        .rms_eps = cfg.rms_eps,
        .seq_len = 1,
        .num_heads = cfg.num_heads,
        .head_dim = cfg.head_dim,
        .rope_theta = cfg.rope_theta,
        .num_kv_heads = cfg.num_kv_heads,
    };
}

fn forwardOne(
    cfg: forward.LayerConfig,
    weights: forward.LayerWeights,
    x_row: tensor.Tensor,
    cache: *kv.KVCache,
    layer_index: usize,
    position: usize,
    buffers: *decode_buffers.LayerBuffers,
    next_h: tensor.Tensor,
    rope_table: *const generate.PreparedTextRopeTableV1,
    phase: generate.PreparedTextPhaseV1,
    mark: ?kv.RowTxnMark,
) !void {
    try generate.forwardPreparedTextLayerSerialV1(
        cfg,
        weights,
        x_row,
        cache,
        layer_index,
        position,
        buffers,
        next_h,
        rope_table,
        phase,
        mark,
    );
}
