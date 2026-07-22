//! End-to-end test: synthesize a tiny transformer as a .glacier file,
//! load it, run a full forward pass, and verify the output is sane.
//!
//! This is the test that proves the whole stack (format → loader →
//! multi-layer forward → logits) connects. It does NOT prove the model
//! produces meaningful predictions — the fixture is random weights — but
//! it does prove:
//!   1. The converter produces a loadable .glacier from safetensors.
//!   2. The loader correctly groups tensors by layer/kind.
//!   3. Multi-layer forward runs without NaN/inf and preserves shape.
//!   4. logits has the right [seq, vocab] shape and is finite.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");

const testing = std.testing;

fn pathInTmp(tmp: *testing.TmpDir, basename: []const u8) ![]u8 {
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);
    return std.fs.path.join(testing.allocator, &.{ root, basename });
}

fn expectExactFloatBits(comptime T: type, expected: []const T, actual: []const T) !void {
    try testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(expected),
        std.mem.sliceAsBytes(actual),
    );
}

fn expectExactInt4(
    expected: engine.int4_weights.Int4WeightData,
    actual: engine.int4_weights.Int4WeightData,
) !void {
    try testing.expectEqual(expected.group_size, actual.group_size);
    try testing.expectEqual(expected.num_elements, actual.num_elements);
    try testing.expectEqual(expected.packed_layout, actual.packed_layout);
    try testing.expectEqualSlices(u8, expected.packed_bytes, actual.packed_bytes);
    try expectExactFloatBits(f32, expected.scales, actual.scales);
    try expectExactFloatBits(f16, expected.scales_f16, actual.scales_f16);
    try expectExactFloatBits(
        f16,
        expected.scales_f16_rows4,
        actual.scales_f16_rows4,
    );
    try testing.expectEqualSlices(i8, expected.expanded_i8, actual.expanded_i8);
}

/// Geometry of the synthetic model. dim=64 so the loader's head_dim=64
/// heuristic activates (single head, but exercises the multi-head code
/// path with num_heads=1 and RoPE).
const DIM: usize = 64;
const HIDDEN: usize = 128;
const VOCAB: usize = 128;
const NUM_LAYERS: usize = 4;

fn generatePairM1Oracle(
    model: engine.loader.LoadedModel,
    request: engine.decode_lane4.Request,
    state: *engine.generate.GenerationStateTelemetry,
) ![]u32 {
    return engine.generate.generate(
        testing.allocator,
        model,
        request.prompt,
        .{
            .max_new_tokens = request.max_new_tokens,
            .eos_token = request.eos_token,
            .sampler = request.sampler,
            .seed = request.seed,
            .num_threads = 1,
            .use_batch_prefill = false,
            .mlp_representation = .pair_nibble_required,
            .decode_frame_mode = .compact_pair_required,
            .parallel_attention_min_context = null,
            .generation_state_telemetry = state,
            .forced_tokens = request.forced_tokens,
        },
    );
}

fn packedInt4Prefix(
    source: engine.int4_weights.Int4WeightData,
    num_elements: usize,
) !engine.int4_weights.Int4WeightData {
    const group_size: usize = @intCast(source.group_size);
    try testing.expect(group_size > 0);
    try testing.expectEqual(
        engine.int4_weights.PackedLayout.rows4_k16,
        source.packed_layout,
    );
    try testing.expectEqual(@as(usize, 0), num_elements % 2);
    try testing.expectEqual(@as(usize, 0), num_elements % group_size);
    try testing.expect(source.num_elements >= num_elements);

    const packed_len = num_elements / 2;
    const scale_count = num_elements / group_size;
    try testing.expect(source.packed_bytes.len >= packed_len);
    try testing.expect(source.scales_f16_rows4.len >= scale_count);
    try testing.expectEqual(@as(usize, 0), source.expanded_i8.len);

    var prefix = source;
    prefix.num_elements = num_elements;
    prefix.packed_bytes = source.packed_bytes[0..packed_len];
    prefix.scales = if (source.scales.len == 0)
        &.{}
    else blk: {
        try testing.expect(source.scales.len >= scale_count);
        break :blk source.scales[0..scale_count];
    };
    prefix.scales_f16 = if (source.scales_f16.len == 0)
        &.{}
    else blk: {
        try testing.expect(source.scales_f16.len >= scale_count);
        break :blk source.scales_f16[0..scale_count];
    };
    prefix.scales_f16_rows4 = source.scales_f16_rows4[0..scale_count];
    return prefix;
}

const CommitObserverContext = struct {
    bank: *engine.resource_bank.Bank,
    calls: usize = 0,
    committed_receipts_at_callback: usize = 0,
    queue_slots_at_callback: u64 = 0,
    evidence_abi: u64 = 0,
    resource_bank_abi: u64 = 0,
    receipt: ?engine.resource_bank.Receipt = null,
    reject: bool = true,

    fn observe(
        raw_context: *anyopaque,
        evidence: *const engine.generate.ResourceCommitEvidenceV1,
    ) engine.generate.ResourceCommitObserverError!void {
        const self: *@This() = @ptrCast(@alignCast(raw_context));
        if (evidence.abi != engine.generate.resource_commit_observer_abi or
            evidence.resource_bank_abi != engine.resource_bank.abi)
            return error.InvalidEvidence;
        const snapshot = self.bank.snapshot() catch return error.Unavailable;
        self.calls += 1;
        self.committed_receipts_at_callback = snapshot.committed_receipts;
        self.queue_slots_at_callback = snapshot.used.queue_slots;
        self.evidence_abi = evidence.abi;
        self.resource_bank_abi = evidence.resource_bank_abi;
        self.receipt = evidence.receipt;
        if (self.reject) return error.Unavailable;
    }
};

const TokenPublicationContext = struct {
    events: [64]engine.generate.TokenPublicationEvidenceV1 = undefined,
    calls: usize = 0,
    reject_at: ?usize = null,

    fn observe(
        raw_context: *anyopaque,
        evidence: *const engine.generate.TokenPublicationEvidenceV1,
    ) engine.generate.TokenPublicationObserverError!void {
        const self: *@This() = @ptrCast(@alignCast(raw_context));
        if (evidence.abi != engine.generate.token_publication_observer_abi or
            self.calls >= self.events.len)
            return error.InvalidEvidence;
        const call_index = self.calls;
        self.calls += 1;
        if (self.reject_at == call_index) return error.Unavailable;
        self.events[call_index] = evidence.*;
    }
};

const TestEligibilityProvider = struct {
    calls: usize = 0,
    fail_step: ?usize = null,
    corrupt_digest: bool = false,
    corrupt_prefix: bool = false,
    empty_mask: bool = false,

    const tokenizer_binding = [_]u8{0x31} ** 32;
    const policy_binding = [_]u8{0x52} ** 32;
    const generation_epoch: u64 = 0x2026_0720;

    fn fill(
        context: *anyopaque,
        step: *const engine.generate.EligibilityStepV1,
        staging_words: []u64,
        certificate: *engine.generate.EligibilityCertificateV1,
    ) engine.generate.EligibilityProviderError!void {
        const self: *TestEligibilityProvider = @ptrCast(@alignCast(context));
        const step_index = std.math.cast(usize, step.step_index) orelse
            return error.InvalidEvidence;
        self.calls += 1;
        if (self.fail_step == step_index) return error.InvalidEvidence;

        if (!self.empty_mask) {
            const base = (3 + step_index * 17) % step.vocab_size;
            for (0..8) |candidate_index| {
                const token_id = (base + candidate_index * 13) %
                    step.vocab_size;
                staging_words[token_id / 64] |=
                    @as(u64, 1) << @as(u6, @intCast(token_id % 64));
            }
        }
        var digest = engine.generate.eligibilityMaskSha256(staging_words);
        if (self.corrupt_digest) digest[0] ^= 0xff;
        var prefix_digest = step.prefix_sha256;
        if (self.corrupt_prefix) prefix_digest[0] ^= 0xff;
        certificate.* = .{
            .abi = engine.generate.eligibility_provider_abi,
            .generation_epoch = step.generation_epoch,
            .request_nonce = step.request_nonce,
            .step_index = step.step_index,
            .logits_position = step.logits_position,
            .not_after_step = step.step_index,
            .head_binding = step.head_binding,
            .tokenizer_binding = step.tokenizer_binding,
            .policy_binding = step.policy_binding,
            .prefix_sha256 = prefix_digest,
            .mask_sha256 = digest,
            .eligible_rows = if (self.empty_mask) 0 else 8,
            .tie_rule = .lowest_token_id,
            .operation = .greedy_argmax,
        };
    }

    fn provider(
        self: *TestEligibilityProvider,
        head_binding: [32]u8,
    ) engine.generate.EligibleVocabularyProvider {
        return .{
            .context = self,
            .generation_epoch = generation_epoch,
            .head_binding = head_binding,
            .tokenizer_binding = tokenizer_binding,
            .policy_binding = policy_binding,
            .fill = fill,
        };
    }
};

const ConcurrentEligibilityRun = struct {
    model: *const engine.loader.LoadedModel,
    prompt: []const u32,
    head_binding: [32]u8,
    provider_context: TestEligibilityProvider = .{},
    telemetry: engine.generate.EligibilityTelemetry = .{},
    tokens: ?[]u32 = null,
    generate_error: ?engine.generate.GenerateError = null,

    fn run(self: *ConcurrentEligibilityRun) void {
        self.tokens = engine.generate.generate(
            std.heap.c_allocator,
            self.model.*,
            self.prompt,
            .{
                .max_new_tokens = 2,
                .num_threads = 1,
                .greedy_output_mode = .domain_prehead_required,
                .eligible_vocabulary_provider = self.provider_context.provider(
                    self.head_binding,
                ),
                .eligibility_telemetry = &self.telemetry,
            },
        ) catch |err| {
            self.generate_error = err;
            return;
        };
    }
};

const TensorSpec = struct {
    name: []const u8,
    shape: []const usize,
    scale: f32, // gaussian sigma for synthetic weights
};

/// Write a synthetic safetensors file representing a tiny Llama-style model.
fn writeTinyModelSafetensors(path: []const u8) !void {
    const allocator = testing.allocator;
    var rng = std.Random.DefaultPrng.init(2024);

    // Each tensor's shape is captured inline (not a slice to stack memory).
    const TensorEntry = struct {
        name: []const u8,
        dims: [4]usize,
        n_dims: u8,
        offset: u64,
        len: u64,
    };

    var tensors: std.ArrayList(TensorEntry) = .{};
    defer {
        // Free owned names.
        for (tensors.items) |t| {
            if (std.mem.startsWith(u8, t.name, "model.layers.")) allocator.free(t.name);
        }
        tensors.deinit(allocator);
    }

    var offset: u64 = 0;

    // Token embedding: [vocab, dim].
    {
        const n = VOCAB * DIM;
        try tensors.append(allocator, .{
            .name = "model.embed_tokens.weight",
            .dims = .{ VOCAB, DIM, 0, 0 },
            .n_dims = 2,
            .offset = offset,
            .len = @intCast(n * 4),
        });
        offset += n * 4;
    }

    // Per-layer tensors.
    const LayerSpec = struct { suffix: []const u8, dims: [4]usize, n_dims: u8 };
    const layer_specs = [_]LayerSpec{
        .{ .suffix = "input_layernorm.weight", .dims = .{ DIM, 0, 0, 0 }, .n_dims = 1 },
        .{ .suffix = "self_attn.q_proj.weight", .dims = .{ DIM, DIM, 0, 0 }, .n_dims = 2 },
        .{ .suffix = "self_attn.k_proj.weight", .dims = .{ DIM, DIM, 0, 0 }, .n_dims = 2 },
        .{ .suffix = "self_attn.v_proj.weight", .dims = .{ DIM, DIM, 0, 0 }, .n_dims = 2 },
        .{ .suffix = "self_attn.o_proj.weight", .dims = .{ DIM, DIM, 0, 0 }, .n_dims = 2 },
        .{ .suffix = "post_attention_layernorm.weight", .dims = .{ DIM, 0, 0, 0 }, .n_dims = 1 },
        .{ .suffix = "mlp.gate_proj.weight", .dims = .{ HIDDEN, DIM, 0, 0 }, .n_dims = 2 },
        .{ .suffix = "mlp.up_proj.weight", .dims = .{ HIDDEN, DIM, 0, 0 }, .n_dims = 2 },
        .{ .suffix = "mlp.down_proj.weight", .dims = .{ DIM, HIDDEN, 0, 0 }, .n_dims = 2 },
    };
    for (0..NUM_LAYERS) |layer| {
        for (layer_specs) |spec| {
            var n: usize = 1;
            for (spec.dims[0..spec.n_dims]) |d| n *= d;
            const name = try std.fmt.allocPrint(allocator, "model.layers.{d}.{s}", .{ layer, spec.suffix });
            try tensors.append(allocator, .{
                .name = name,
                .dims = spec.dims,
                .n_dims = spec.n_dims,
                .offset = offset,
                .len = @intCast(n * 4),
            });
            offset += n * 4;
        }
    }

    // Final norm + lm_head.
    {
        try tensors.append(allocator, .{
            .name = "model.norm.weight",
            .dims = .{ DIM, 0, 0, 0 },
            .n_dims = 1,
            .offset = offset,
            .len = @intCast(DIM * 4),
        });
        offset += DIM * 4;
    }
    {
        const n = VOCAB * DIM;
        try tensors.append(allocator, .{
            .name = "lm_head.weight",
            .dims = .{ VOCAB, DIM, 0, 0 },
            .n_dims = 2,
            .offset = offset,
            .len = @intCast(n * 4),
        });
        offset += n * 4;
    }

    // Build JSON header into a fixed buffer using a streaming writer.
    var json_buf: [16384]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&json_buf);
    const jw = fbs.writer();
    try jw.writeAll("{");
    var first = true;
    for (tensors.items) |t| {
        if (!first) try jw.writeAll(",");
        first = false;
        try jw.writeAll("\"");
        try jw.writeAll(t.name);
        try jw.writeAll("\":{\"dtype\":\"F32\",\"shape\":[");
        for (t.dims[0..t.n_dims], 0..) |d, i| {
            if (i > 0) try jw.writeAll(",");
            try jw.print("{d}", .{d});
        }
        try jw.writeAll("],\"data_offsets\":[");
        try jw.print("{d},{d}", .{ t.offset, t.offset + t.len });
        try jw.writeAll("]}");
    }
    try jw.writeAll(",\"__metadata__\":{\"format\":\"pt\"}}");
    const json_slice = json_buf[0..fbs.pos];

    // Write file: [u64 header_len][json][data...].
    const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();

    var hdr_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &hdr_buf, @intCast(json_slice.len), .little);
    try f.writeAll(&hdr_buf);
    try f.writeAll(json_slice);

    // Write data region: random gaussian weights per tensor.
    for (tensors.items) |t| {
        var n: usize = 1;
        for (t.dims[0..t.n_dims]) |d| n *= d;
        const scale: f32 = if (std.mem.indexOf(u8, t.name, "embed") != null or
            std.mem.indexOf(u8, t.name, "lm_head") != null)
            0.02
        else if (std.mem.indexOf(u8, t.name, "layernorm") != null)
            0.05
        else
            0.04;
        var bytes: [4]u8 = undefined;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const v: f32 = rng.random().floatNorm(f32) * scale;
            std.mem.writeInt(u32, &bytes, @bitCast(v), .little);
            try f.writeAll(&bytes);
        }
    }
}

test "end-to-end: convert → load → multi-layer forward → logits" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const st_path = try pathInTmp(&tmp, "model.safetensors");
    defer testing.allocator.free(st_path);
    const glacier_path = try pathInTmp(&tmp, "model.glacier");
    defer testing.allocator.free(glacier_path);

    try writeTinyModelSafetensors(st_path);

    // Convert to .glacier with INT4 quantization on the projectable tensors.
    // Use a generous page size so each tensor fits in one page (the loader
    // MVP requires single-page tensors).
    const result = try engine.converter.convertSafetensors(
        testing.allocator,
        st_path,
        glacier_path,
        .{
            .quantize_int4 = true,
            .quant_group_size = 16, // DIM=16 → exactly one group per row chunk
            .page_size_bytes = 1 << 16, // 64 KiB → fits any tensor here
        },
    );
    // embed(1) + 4 layers × 9 tensors (36) + final norm(1) + lm_head(1) = 39.
    try testing.expectEqual(@as(u64, 1 + 4 * 9 + 2), result.num_pages);

    // Load the model.
    var reader = try engine.model.FileReader.open(testing.allocator, glacier_path);
    defer reader.close();
    var model = try engine.loader.load(testing.allocator, &reader, .{});
    defer model.deinit();

    try testing.expectEqual(@as(usize, NUM_LAYERS), model.config.num_layers);
    // dim is detected from the largest attn row_end. With page_size 64 KiB
    // and dim=16, each attn tensor is one page with row_end=16.
    try testing.expectEqual(@as(usize, DIM), model.config.dim);

    // Run a forward pass over a short prompt.
    const prompt = [_]u32{ 1, 2, 3, 5 };
    var logits = try engine.core.tensor.zerosF32(
        testing.allocator,
        &.{ prompt.len, model.config.vocab_size },
    );
    defer logits.deinit();
    try engine.forward.forwardModel(testing.allocator, model, &prompt, logits);

    // Logits shape + finiteness.
    try testing.expectEqual(@as(usize, prompt.len), logits.shape[0]);
    try testing.expectEqual(model.config.vocab_size, logits.shape[1]);
    var finite_count: usize = 0;
    for (logits.asF32()) |v| if (std.math.isFinite(v)) {
        finite_count += 1;
    };
    try testing.expectEqual(logits.asF32().len, finite_count);

    // Argmax of the last position gives a predicted next token in range.
    const last_row = logits.asF32()[(prompt.len - 1) * model.config.vocab_size ..];
    const next = engine.forward.argmax(last_row);
    try testing.expect(next < model.config.vocab_size);
}

test "perplexity computation runs end-to-end on fixture model" {
    // Reuse the same fixture as the forward test. The model is random
    // weights so the perplexity number itself is meaningless — we only
    // assert that the computation runs without errors and returns a
    // finite, positive value in a sane range.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const st_path = try pathInTmp(&tmp, "model.safetensors");
    defer testing.allocator.free(st_path);
    const glacier_path = try pathInTmp(&tmp, "model.glacier");
    defer testing.allocator.free(glacier_path);

    try writeTinyModelSafetensors(st_path);
    _ = try engine.converter.convertSafetensors(
        testing.allocator,
        st_path,
        glacier_path,
        .{
            .quantize_int4 = true,
            .quant_group_size = 16,
            .page_size_bytes = 1 << 16,
        },
    );

    var reader = try engine.model.FileReader.open(testing.allocator, glacier_path);
    defer reader.close();
    var model = try engine.loader.load(testing.allocator, &reader, .{});
    defer model.deinit();

    // 8-token eval sequence.
    const eval_ids = [_]u32{ 1, 5, 2, 7, 0, 3, 6, 4 };
    const result = try engine.perplexity.compute(
        testing.allocator,
        model,
        &eval_ids,
        4, // batch_len
    );

    try testing.expectEqual(eval_ids.len - 1, result.num_predictions);
    try testing.expect(std.math.isFinite(result.mean_nll));
    try testing.expect(std.math.isFinite(result.perplexity));
    try testing.expect(result.mean_nll > 0);
    try testing.expect(result.perplexity > 1.0);
    // For a vocab of 64 with random weights, perplexity should be close
    // to 64 (uniform). Allow a wide band; we just sanity-check the math.
    try testing.expect(result.perplexity < 4 * @as(f64, @floatFromInt(model.config.vocab_size)));

    const llama_compatible = try engine.perplexity.computeLlamaCompatible(
        testing.allocator,
        model,
        &eval_ids,
        4,
    );
    try testing.expectEqual(@as(usize, 2), llama_compatible.num_predictions);
    try testing.expect(std.math.isFinite(llama_compatible.perplexity));
}

test "multi-page tensors load and forward correctly" {
    // Force every tensor to span multiple pages by using a tiny page size.
    // Each q_proj is DIM×DIM = 256 f32 = 1024 bytes; with page_size 128 bytes
    // (32 elements) each q_proj becomes 8 pages. The loader must concat them
    // back into a single 256-element weight matrix transparently.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const st_path = try pathInTmp(&tmp, "model.safetensors");
    defer testing.allocator.free(st_path);
    const glacier_path = try pathInTmp(&tmp, "model.glacier");
    defer testing.allocator.free(glacier_path);

    try writeTinyModelSafetensors(st_path);

    const result = try engine.converter.convertSafetensors(
        testing.allocator,
        st_path,
        glacier_path,
        .{
            .quantize_int4 = true,
            .quant_group_size = 8,
            // 128 bytes per page = 16 f32 elements or 32 INT4-packed elements.
            // q_proj has 256 elements → splits across multiple pages.
            .page_size_bytes = 128,
        },
    );
    // With tiny pages, every tensor must produce >1 page.
    try testing.expect(result.num_pages > 100);

    // The loader must successfully decode and concatenate all pages per
    // tensor — BadPayload was the pre-multi-page error and must NOT fire.
    var reader = try engine.model.FileReader.open(testing.allocator, glacier_path);
    defer reader.close();
    var model = try engine.loader.load(testing.allocator, &reader, .{});
    defer model.deinit();

    try testing.expectEqual(@as(usize, NUM_LAYERS), model.config.num_layers);
    try testing.expectEqual(@as(usize, DIM), model.config.dim);

    // Each per-layer weight matrix must have exactly DIM×DIM elements
    // (concatenated correctly from multi-page decode).
    for (model.layers) |lw| {
        try testing.expectEqual(DIM * DIM, lw.wq.len);
        try testing.expectEqual(DIM * DIM, lw.wk.len);
        try testing.expectEqual(DIM * DIM, lw.wv.len);
        try testing.expectEqual(DIM * DIM, lw.wo.len);
        try testing.expectEqual(HIDDEN * DIM, lw.w_gate.len);
        try testing.expectEqual(HIDDEN * DIM, lw.w_up.len);
        try testing.expectEqual(DIM * HIDDEN, lw.w_down.len);
    }

    // Forward pass must run end-to-end on the multi-page-loaded model.
    const prompt = [_]u32{ 1, 2, 3 };
    var logits = try engine.core.tensor.zerosF32(
        testing.allocator,
        &.{ prompt.len, model.config.vocab_size },
    );
    defer logits.deinit();
    try engine.forward.forwardModel(testing.allocator, model, &prompt, logits);

    // All logits finite.
    for (logits.asF32()) |v| try testing.expect(std.math.isFinite(v));
}

test "compact multi-page INT4 generation matches eager generation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const st_path = try pathInTmp(&tmp, "model.safetensors");
    defer testing.allocator.free(st_path);
    const glacier_path = try pathInTmp(&tmp, "model.glacier");
    defer testing.allocator.free(glacier_path);

    try writeTinyModelSafetensors(st_path);
    _ = try engine.converter.convertSafetensors(
        testing.allocator,
        st_path,
        glacier_path,
        .{
            .quantize_int4 = true,
            .quant_group_size = 8,
            .page_size_bytes = 128,
        },
    );

    var eager_reader = try engine.model.FileReader.open(testing.allocator, glacier_path);
    defer eager_reader.close();
    var eager = try engine.loader.load(testing.allocator, &eager_reader, .{});
    defer eager.deinit();

    var compact_reader = try engine.model.FileReader.open(testing.allocator, glacier_path);
    defer compact_reader.close();
    var compact = try engine.loader.loadWithOptions(testing.allocator, &compact_reader, .{}, .{
        .compact_int4 = true,
    });
    defer compact.deinit();

    try testing.expectEqual(@as(usize, 0), compact.token_embedding.len);
    try testing.expect(compact.token_embedding_int4 != null);
    try testing.expectEqual(VOCAB * DIM, compact.token_embedding_int4.?.numElements());
    for (compact.layers) |layer| {
        try testing.expectEqual(@as(usize, 0), layer.wq.len);
        try testing.expect(layer.wq_int4 != null);
        try testing.expectEqual(DIM * DIM, layer.wq_int4.?.numElements());
        try testing.expectEqual(HIDDEN * DIM, layer.w_up_int4.?.numElements());
    }

    // The compact embedding row must be numerically identical to the eager
    // dequantized representation before exercising the full decode path.
    var compact_row: [DIM]f32 = undefined;
    try engine.int4_matmul.dequantizeRow(compact.token_embedding_int4.?, 7, DIM, &compact_row);
    for (compact_row, eager.token_embedding[7 * DIM .. 8 * DIM]) |actual, expected| {
        try testing.expectApproxEqAbs(expected, actual, 1e-7);
    }

    const prompt = [_]u32{ 1, 2, 3 };
    const eager_tokens = try engine.generate.generate(testing.allocator, eager, &prompt, .{
        .max_new_tokens = 4,
    });
    defer testing.allocator.free(eager_tokens);
    const compact_tokens = try engine.generate.generate(testing.allocator, compact, &prompt, .{
        .max_new_tokens = 4,
    });
    defer testing.allocator.free(compact_tokens);
    try testing.expectEqualSlices(u32, eager_tokens, compact_tokens);

    // ResourceBank admission is an execution contract, not a numerical path:
    // an unlimited committed receipt must preserve the exact token stream and
    // return every charged dimension before `generate` hands output ownership
    // to this caller.
    var resource_slots = [_]engine.resource_bank.Slot{.{}} ** 1;
    var request_bank = try engine.resource_bank.Bank.init(
        &resource_slots,
        .{},
        0x5445_5354,
    );
    var resource_telemetry: engine.generate.RequestResourceTelemetry = .{};
    var resource_observer: CommitObserverContext = .{
        .bank = &request_bank,
        .reject = false,
    };
    var token_observer: TokenPublicationContext = .{};
    const admitted_tokens = try engine.generate.generate(
        testing.allocator,
        compact,
        &prompt,
        .{
            .max_new_tokens = 4,
            .num_threads = 1,
            .request_resource_bank = &request_bank,
            .request_resource_telemetry = &resource_telemetry,
            .resource_commit_observer = .{
                .context = &resource_observer,
                .observe = CommitObserverContext.observe,
            },
            .token_publication_observer = .{
                .logical_request_index = 2,
                .context = &token_observer,
                .observe = TokenPublicationContext.observe,
            },
        },
    );
    defer testing.allocator.free(admitted_tokens);
    try testing.expectEqualSlices(u32, compact_tokens, admitted_tokens);
    try testing.expect(resource_telemetry.owner_key != 0);
    try testing.expectEqual(@as(u32, 0), resource_telemetry.receipt_slot_index);
    try testing.expectEqual(@as(u64, 1), resource_telemetry.receipt_generation);
    try testing.expect(resource_telemetry.receipt_integrity != 0);
    try testing.expectEqual(@as(u64, 12_416), resource_telemetry.kv_bytes);
    try testing.expectEqual(@as(u64, 4_368), resource_telemetry.activation_bytes);
    try testing.expectEqual(@as(u64, 528), resource_telemetry.logits_bytes);
    try testing.expectEqual(@as(u64, 1_536), resource_telemetry.staging_bytes);
    try testing.expectEqual(@as(u64, 28), resource_telemetry.output_journal_bytes);
    try testing.expectEqual(@as(u64, 18_876), resource_telemetry.host_claim_bytes);
    try testing.expectEqual(resource_telemetry.host_claim_bytes, resource_telemetry.peak_host_bytes);
    try testing.expectEqual(@as(u64, 1), resource_telemetry.reservations);
    try testing.expectEqual(@as(u64, 1), resource_telemetry.commits);
    try testing.expectEqual(@as(u64, 1), resource_telemetry.releases);
    try testing.expectEqual(@as(usize, 0), resource_telemetry.active_reservations);
    try testing.expectEqual(@as(usize, 0), resource_telemetry.committed_receipts);
    try testing.expectEqual(@as(usize, 0), resource_telemetry.release_failures);
    try testing.expectEqual(@as(usize, 1), resource_observer.calls);
    try testing.expectEqual(@as(usize, 1), resource_observer.committed_receipts_at_callback);
    try testing.expectEqual(@as(u64, 1), resource_observer.queue_slots_at_callback);
    try testing.expectEqual(
        resource_telemetry.owner_key,
        resource_observer.receipt.?.owner_key,
    );
    try testing.expectEqual(@as(usize, 4), token_observer.calls);
    for (token_observer.events[0..token_observer.calls], 0..) |event, step| {
        try testing.expectEqual(@as(u32, 2), event.logical_request_index);
        try testing.expectEqual(@as(u64, @intCast(step)), event.step_index);
        try testing.expectEqual(admitted_tokens[step], event.token_id);
        try testing.expectEqual(step + 1 == admitted_tokens.len, event.terminal);
    }
    try testing.expect((try request_bank.snapshot()).used.isZero());

    // Observer rejection is still post-commit but strictly pre-allocation.
    // A fail-at-zero caller allocator must therefore remain untouched while
    // the sole receipt guard releases the committed claim exactly once.
    var observer_reject_slots = [_]engine.resource_bank.Slot{.{}} ** 1;
    var observer_reject_bank = try engine.resource_bank.Bank.init(
        &observer_reject_slots,
        .{},
        0x5445_5357,
    );
    var observer_reject_resources: engine.generate.RequestResourceTelemetry = .{};
    var rejecting_observer: CommitObserverContext = .{
        .bank = &observer_reject_bank,
    };
    var untouched_allocator = std.testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    try testing.expectError(
        engine.generate.GenerateError.ResourceCommitObserverRejected,
        engine.generate.generate(untouched_allocator.allocator(), compact, &prompt, .{
            .max_new_tokens = 4,
            .num_threads = 1,
            .request_resource_bank = &observer_reject_bank,
            .request_resource_telemetry = &observer_reject_resources,
            .resource_commit_observer = .{
                .context = &rejecting_observer,
                .observe = CommitObserverContext.observe,
            },
        }),
    );
    try testing.expect(!untouched_allocator.has_induced_failure);
    try testing.expectEqual(@as(usize, 1), rejecting_observer.calls);
    try testing.expectEqual(
        @as(usize, 1),
        rejecting_observer.committed_receipts_at_callback,
    );
    try testing.expectEqual(@as(u64, 1), rejecting_observer.queue_slots_at_callback);
    try testing.expectEqual(@as(u64, 1), observer_reject_resources.reservations);
    try testing.expectEqual(@as(u64, 1), observer_reject_resources.commits);
    try testing.expectEqual(@as(u64, 1), observer_reject_resources.releases);
    try testing.expectEqual(@as(usize, 0), observer_reject_resources.release_failures);
    try testing.expect((try observer_reject_bank.snapshot()).used.isZero());

    var token_reject_slots = [_]engine.resource_bank.Slot{.{}} ** 1;
    var token_reject_bank = try engine.resource_bank.Bank.init(
        &token_reject_slots,
        .{},
        0x5445_5358,
    );
    var token_reject_resources: engine.generate.RequestResourceTelemetry = .{};
    var token_reject_context: TokenPublicationContext = .{ .reject_at = 0 };
    try testing.expectError(
        engine.generate.GenerateError.TokenPublicationObserverRejected,
        engine.generate.generate(testing.allocator, compact, &prompt, .{
            .max_new_tokens = 4,
            .num_threads = 1,
            .request_resource_bank = &token_reject_bank,
            .request_resource_telemetry = &token_reject_resources,
            .token_publication_observer = .{
                .logical_request_index = 1,
                .context = &token_reject_context,
                .observe = TokenPublicationContext.observe,
            },
        }),
    );
    try testing.expectEqual(@as(usize, 1), token_reject_context.calls);
    try testing.expectEqual(@as(u64, 1), token_reject_resources.reservations);
    try testing.expectEqual(@as(u64, 1), token_reject_resources.commits);
    try testing.expectEqual(@as(u64, 1), token_reject_resources.releases);
    try testing.expectEqual(@as(usize, 0), token_reject_resources.release_failures);
    try testing.expect((try token_reject_bank.snapshot()).used.isZero());

    // One byte below the derived request bound rejects before any reservation
    // can commit and leaves the shared authority reusable.
    var capped_slots = [_]engine.resource_bank.Slot{.{}} ** 1;
    var capped_bank = try engine.resource_bank.Bank.init(
        &capped_slots,
        .{ .host_bytes = resource_telemetry.host_claim_bytes - 1 },
        0x5445_5355,
    );
    var rejected_resources: engine.generate.RequestResourceTelemetry = .{};
    try testing.expectError(
        engine.generate.GenerateError.ResourceBudgetExceeded,
        engine.generate.generate(testing.allocator, compact, &prompt, .{
            .max_new_tokens = 4,
            .num_threads = 1,
            .request_resource_bank = &capped_bank,
            .request_resource_telemetry = &rejected_resources,
        }),
    );
    try testing.expectEqual(@as(u64, 0), rejected_resources.reservations);
    try testing.expectEqual(@as(u64, 0), rejected_resources.commits);
    try testing.expectEqual(
        std.math.maxInt(u32),
        rejected_resources.receipt_slot_index,
    );
    try testing.expectEqual(@as(u64, 0), rejected_resources.receipt_generation);
    try testing.expectEqual(@as(u64, 1), rejected_resources.capacity_rejects);
    try testing.expect((try capped_bank.snapshot()).used.isZero());

    // Admission precedes request allocation. If the first allocation fails
    // after commit, the function-level receipt guard must still release every
    // charged dimension and leave the authority reusable.
    var failing_slots = [_]engine.resource_bank.Slot{.{}} ** 1;
    var failing_bank = try engine.resource_bank.Bank.init(
        &failing_slots,
        .{},
        0x5445_5356,
    );
    var failing_resources: engine.generate.RequestResourceTelemetry = .{};
    var failing_allocator = std.testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    try testing.expectError(
        engine.generate.GenerateError.OutOfMemory,
        engine.generate.generate(failing_allocator.allocator(), compact, &prompt, .{
            .max_new_tokens = 4,
            .num_threads = 1,
            .request_resource_bank = &failing_bank,
            .request_resource_telemetry = &failing_resources,
        }),
    );
    try testing.expect(failing_allocator.has_induced_failure);
    try testing.expectEqual(@as(u64, 1), failing_resources.reservations);
    try testing.expectEqual(@as(u64, 1), failing_resources.commits);
    try testing.expectEqual(@as(u64, 1), failing_resources.releases);
    try testing.expectEqual(@as(usize, 0), failing_resources.release_failures);
    try testing.expect((try failing_bank.snapshot()).used.isZero());
}

test "prepared runtime image exactly preserves compact multi-page model" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const st_path = try pathInTmp(&tmp, "model.safetensors");
    defer testing.allocator.free(st_path);
    const glacier_path = try pathInTmp(&tmp, "model.glacier");
    defer testing.allocator.free(glacier_path);
    const prepared_path = try pathInTmp(&tmp, "model.glrt");
    defer testing.allocator.free(prepared_path);
    const pair_prepared_path = try pathInTmp(&tmp, "model-pair.glrt");
    defer testing.allocator.free(pair_prepared_path);
    const g16_glacier_path = try pathInTmp(&tmp, "model-g16.glacier");
    defer testing.allocator.free(g16_glacier_path);
    const g16_pair_prepared_path = try pathInTmp(&tmp, "model-pair-g16.glrt");
    defer testing.allocator.free(g16_pair_prepared_path);

    try writeTinyModelSafetensors(st_path);
    _ = try engine.converter.convertSafetensors(
        testing.allocator,
        st_path,
        glacier_path,
        .{
            .quantize_int4 = true,
            .quant_group_size = 8,
            .page_size_bytes = 128,
        },
    );

    var reader = try engine.model.FileReader.open(testing.allocator, glacier_path);
    defer reader.close();
    var materialized = try engine.loader.loadWithOptions(
        testing.allocator,
        &reader,
        .{},
        .{
            .compact_int4 = true,
            .fp16_scale_cache = true,
        },
    );
    defer materialized.deinit();

    const source_fingerprint = materialized.source_fingerprint;
    try testing.expect(!std.mem.eql(
        u8,
        &source_fingerprint,
        &([_]u8{0} ** 32),
    ));
    try engine.loader.writePrepared(
        testing.allocator,
        &materialized,
        prepared_path,
        source_fingerprint,
    );
    try engine.loader.writePreparedWithOptions(
        testing.allocator,
        &materialized,
        pair_prepared_path,
        source_fingerprint,
        .{ .mlp_layout = .pair_nibble_required },
    );

    var stale_fingerprint = source_fingerprint;
    stale_fingerprint[0] ^= 0xff;
    try testing.expectError(
        engine.loader.LoaderError.StalePreparedImage,
        engine.loader.loadPreparedWithOptions(testing.allocator, prepared_path, .{
            .expected_source_fingerprint = stale_fingerprint,
        }),
    );

    var mapped = try engine.loader.loadPreparedWithOptions(
        testing.allocator,
        prepared_path,
        .{ .expected_source_fingerprint = source_fingerprint },
    );
    defer mapped.deinit();
    var pair_mapped = try engine.loader.loadPreparedWithOptions(
        testing.allocator,
        pair_prepared_path,
        .{
            .expected_source_fingerprint = source_fingerprint,
            .mlp_layout = .pair_nibble_required,
        },
    );
    defer pair_mapped.deinit();

    try testing.expectEqualDeep(materialized.config, mapped.config);
    try expectExactFloatBits(f32, materialized.final_norm, mapped.final_norm);
    try testing.expectEqual(materialized.layers.len, mapped.layers.len);
    for (materialized.layers, mapped.layers) |expected, actual| {
        try expectExactFloatBits(f32, expected.input_norm, actual.input_norm);
        try expectExactFloatBits(f32, expected.post_attn_norm, actual.post_attn_norm);
        try expectExactFloatBits(f32, expected.bq, actual.bq);
        try expectExactFloatBits(f32, expected.bk, actual.bk);
        try expectExactFloatBits(f32, expected.bv, actual.bv);
        try expectExactFloatBits(f32, expected.bo, actual.bo);
        try expectExactInt4(expected.wq_int4.?, actual.wq_int4.?);
        try expectExactInt4(expected.wk_int4.?, actual.wk_int4.?);
        try expectExactInt4(expected.wv_int4.?, actual.wv_int4.?);
        try expectExactInt4(expected.wo_int4.?, actual.wo_int4.?);
        try expectExactInt4(expected.w_gate_int4.?, actual.w_gate_int4.?);
        try expectExactInt4(expected.w_up_int4.?, actual.w_up_int4.?);
        try expectExactInt4(expected.w_down_int4.?, actual.w_down_int4.?);
    }
    try expectExactInt4(
        materialized.token_embedding_int4.?,
        mapped.token_embedding_int4.?,
    );
    try expectExactInt4(materialized.lm_head_int4.?, mapped.lm_head_int4.?);

    // The embedding retains reference FP32 scales while the production
    // rows4/K16 stream carries its exact four-row-interleaved FP16 grid.
    try testing.expect(materialized.token_embedding_int4.?.scales.len > 0);
    try testing.expect(materialized.token_embedding_int4.?.scales_f16_rows4.len > 0);

    const prompt = [_]u32{ 1, 2, 3 };
    const expected_tokens = try engine.generate.generate(
        testing.allocator,
        materialized,
        &prompt,
        .{ .max_new_tokens = 4, .num_threads = 1 },
    );
    defer testing.allocator.free(expected_tokens);
    var separate_storage_telemetry: engine.generate.PairNibbleExecutionTelemetry = .{};
    var separate_scratch_telemetry: engine.generate.PairScratchExecutionTelemetry = .{};
    const actual_tokens = try engine.generate.generate(
        testing.allocator,
        mapped,
        &prompt,
        .{
            .max_new_tokens = 4,
            .num_threads = 1,
            .pair_nibble_telemetry = &separate_storage_telemetry,
            .pair_scratch_telemetry = &separate_scratch_telemetry,
        },
    );
    defer testing.allocator.free(actual_tokens);
    try testing.expectEqualSlices(u32, expected_tokens, actual_tokens);
    try testing.expectEqual(
        @as(usize, 1),
        separate_storage_telemetry.decode_frame_materialized_uses,
    );
    try testing.expectEqual(
        @as(usize, 0),
        separate_storage_telemetry.decode_frame_compact_pair_uses,
    );
    try testing.expectEqual(
        separate_storage_telemetry.decode_frame_materialized_bytes,
        separate_storage_telemetry.decode_frame_tensor_bytes,
    );
    try testing.expectEqual(
        @as(usize, 0),
        separate_storage_telemetry.decode_frame_reclaimed_bytes,
    );
    try testing.expectEqual(
        engine.int4_executor.PairScratchPolicy.disabled,
        separate_scratch_telemetry.selected_policy,
    );
    try testing.expectEqual(@as(usize, 0), separate_scratch_telemetry.participants);
    try testing.expectEqual(@as(usize, 0), separate_scratch_telemetry.producer_g8_layers);
    try testing.expectEqual(@as(usize, 0), separate_scratch_telemetry.producer_g16_layers);
    try testing.expectEqual(@as(usize, 0), separate_scratch_telemetry.bytes);
    try testing.expectEqual(@as(usize, 0), separate_scratch_telemetry.allocations);
    try testing.expectEqual(@as(u64, 0), separate_scratch_telemetry.fixed_dispatches);
    try testing.expectEqual(@as(u64, 0), separate_scratch_telemetry.model_shaped_dispatches);
    try testing.expectEqual(@as(usize, 0), separate_scratch_telemetry.fallbacks);
    try testing.expectEqual(@as(usize, 0), separate_scratch_telemetry.rejects);

    // PairNibble is a strict request-level representation: the pair-only
    // image has no resident legacy gate/up stream, serial M1 consumes one
    // shared activation quantization, and the default policy rejects it
    // before touching even an allocator configured to fail immediately.
    for (pair_mapped.layers) |layer| {
        try testing.expect(layer.w_gate_up_pair_int4 != null);
        try testing.expect(layer.w_gate_int4 == null);
        try testing.expect(layer.w_up_int4 == null);
        try testing.expectEqual(@as(usize, 0), layer.w_gate.len);
        try testing.expectEqual(@as(usize, 0), layer.w_up.len);
        try testing.expectEqual(@as(usize, 0), layer.w_gate_f16.len);
        try testing.expectEqual(@as(usize, 0), layer.w_up_f16.len);
    }
    var pair_serial_telemetry: engine.generate.PairNibbleExecutionTelemetry = .{};
    var pair_serial_scratch: engine.generate.PairScratchExecutionTelemetry = .{};
    var pair_serial_execution: engine.generate.RequestExecutionTelemetry = .{};
    const pair_serial_tokens = try engine.generate.generate(
        testing.allocator,
        pair_mapped,
        &prompt,
        .{
            .max_new_tokens = 4,
            .num_threads = 1,
            .use_batch_prefill = false,
            .mlp_representation = .pair_nibble_required,
            .pair_nibble_telemetry = &pair_serial_telemetry,
            .pair_scratch_telemetry = &pair_serial_scratch,
            .request_execution_telemetry = &pair_serial_execution,
        },
    );
    defer testing.allocator.free(pair_serial_tokens);
    try testing.expectEqualSlices(u32, actual_tokens, pair_serial_tokens);
    try testing.expect(pair_serial_execution.complete);
    try testing.expectEqual(
        engine.generate.request_execution_telemetry_abi,
        pair_serial_execution.abi_version,
    );
    try testing.expectEqual(@as(usize, 1), pair_serial_execution.admitted_requests);
    try testing.expectEqual(@as(usize, 1), pair_serial_execution.thread_participants);
    try testing.expectEqual(prompt.len, pair_serial_execution.prompt_token_graphs);
    try testing.expectEqual(
        pair_serial_tokens.len - 1,
        pair_serial_execution.decode_token_graphs,
    );
    const expected_serial_graphs = prompt.len + pair_serial_tokens.len - 1;
    const expected_serial_layers = expected_serial_graphs * NUM_LAYERS;
    try testing.expectEqual(expected_serial_graphs, pair_serial_execution.token_graphs);
    try testing.expectEqual(expected_serial_graphs, pair_serial_execution.active_lane_steps);
    try testing.expectEqual(expected_serial_layers, pair_serial_execution.layer_graphs);
    try testing.expectEqual(
        expected_serial_layers * 5,
        pair_serial_execution.projection_dispatches,
    );
    try testing.expectEqual(
        expected_serial_layers * 3,
        pair_serial_execution.qkv_projection_dispatches,
    );
    try testing.expectEqual(expected_serial_layers, pair_serial_execution.pair_dispatches);
    try testing.expectEqual(pair_serial_tokens.len, pair_serial_execution.lm_head_dispatches);
    var invalid_execution: engine.generate.RequestExecutionTelemetry = .{
        .complete = true,
        .token_graphs = 99,
    };
    var invalid_execution_allocator = std.testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    try testing.expectError(
        engine.generate.GenerateError.ResourceAdmissionUnavailable,
        engine.generate.generate(
            invalid_execution_allocator.allocator(),
            pair_mapped,
            &prompt,
            .{
                .max_new_tokens = 4,
                .num_threads = 1,
                .mlp_representation = .pair_nibble_required,
                // The evidence ABI forbids batch prefill, whose physical
                // dispatch geometry differs from the serial M1 oracle.
                .use_batch_prefill = true,
                .request_execution_telemetry = &invalid_execution,
            },
        ),
    );
    try testing.expect(!invalid_execution.complete);
    try testing.expectEqual(@as(usize, 0), invalid_execution.token_graphs);
    try testing.expectEqual(@as(usize, 0), invalid_execution_allocator.allocations);
    try testing.expect(!invalid_execution_allocator.has_induced_failure);
    try testing.expectEqual(
        @as(usize, 0),
        pair_serial_telemetry.decode_frame_materialized_uses,
    );
    try testing.expectEqual(
        @as(usize, 1),
        pair_serial_telemetry.decode_frame_compact_pair_uses,
    );
    try testing.expectEqual(HIDDEN, pair_serial_telemetry.pair_q8_scratch_bytes);
    try testing.expect(
        pair_serial_telemetry.pair_activation_scale_bytes > 0 and
            pair_serial_telemetry.pair_activation_scale_bytes < HIDDEN,
    );
    try testing.expect(
        pair_serial_telemetry.decode_frame_tensor_bytes <
            pair_serial_telemetry.decode_frame_materialized_bytes,
    );
    try testing.expectEqual(
        pair_serial_telemetry.decode_frame_materialized_bytes -
            pair_serial_telemetry.decode_frame_tensor_bytes,
        pair_serial_telemetry.decode_frame_reclaimed_bytes,
    );
    try testing.expectEqual(
        NUM_LAYERS,
        pair_serial_telemetry.down_g8_layers +
            pair_serial_telemetry.down_g16_layers,
    );
    try testing.expectEqual(@as(usize, 1), pair_serial_telemetry.admissions);
    try testing.expectEqual(NUM_LAYERS, pair_serial_telemetry.artifact_layers);
    try testing.expectEqual(NUM_LAYERS, pair_serial_telemetry.selected_layers);
    try testing.expect(pair_serial_telemetry.pair_weight_bytes > 0);
    try testing.expect(pair_serial_telemetry.pair_scale_bytes > 0);
    try testing.expectEqual(@as(usize, 0), pair_serial_telemetry.separate_gate_bytes);
    try testing.expectEqual(@as(usize, 0), pair_serial_telemetry.separate_up_bytes);
    try testing.expectEqual(
        prompt.len * NUM_LAYERS,
        pair_serial_telemetry.prefill_m1_dispatches,
    );
    try testing.expectEqual(
        @as(usize, 3 * NUM_LAYERS),
        pair_serial_telemetry.decode_m1_dispatches,
    );
    try testing.expectEqual(
        pair_serial_telemetry.prefill_m1_dispatches +
            pair_serial_telemetry.decode_m1_dispatches,
        pair_serial_telemetry.outputless_m1_dispatches,
    );
    try testing.expectEqual(
        pair_serial_telemetry.prefill_m1_dispatches +
            pair_serial_telemetry.decode_m1_dispatches,
        pair_serial_telemetry.activation_rows_quantized,
    );
    try testing.expectEqual(
        pair_serial_telemetry.activation_rows_quantized,
        pair_serial_telemetry.selected_layer_rows,
    );
    try testing.expectEqual(
        pair_serial_telemetry.selected_layer_rows,
        pair_serial_telemetry.checked_dispatches,
    );
    try testing.expectEqual(@as(usize, 0), pair_serial_telemetry.sealed_dispatches);
    try testing.expectEqual(@as(usize, 0), pair_serial_telemetry.fallbacks);
    try testing.expectEqual(@as(usize, 0), pair_serial_telemetry.rejects);
    try testing.expectEqual(
        engine.int4_executor.PairScratchPolicy.fixed_256,
        pair_serial_scratch.selected_policy,
    );
    try testing.expectEqual(@as(usize, 1), pair_serial_scratch.participants);
    try testing.expectEqual(NUM_LAYERS, pair_serial_scratch.producer_g8_layers);
    try testing.expectEqual(@as(usize, 0), pair_serial_scratch.producer_g16_layers);
    try testing.expectEqual(@as(usize, 256), pair_serial_scratch.selected_g8_rows);
    try testing.expectEqual(@as(usize, 0), pair_serial_scratch.selected_g16_rows);
    try testing.expectEqual(@as(usize, 256), pair_serial_scratch.capacity_rows);
    try testing.expectEqual(@as(usize, 256), pair_serial_scratch.branch_stride_rows);
    try testing.expectEqual(@as(usize, 512), pair_serial_scratch.participant_stride_rows);
    try testing.expectEqual(@as(usize, 512), pair_serial_scratch.f32_elements);
    try testing.expectEqual(@as(usize, 2048), pair_serial_scratch.bytes);
    try testing.expectEqual(@as(usize, 2048), pair_serial_scratch.fixed_counterfactual_bytes);
    try testing.expectEqual(@as(usize, 0), pair_serial_scratch.reclaimed_bytes);
    try testing.expectEqual(@as(usize, 1), pair_serial_scratch.allocations);
    try testing.expectEqual(
        @as(u64, @intCast(pair_serial_telemetry.outputless_m1_dispatches)),
        pair_serial_scratch.fixed_dispatches,
    );
    try testing.expectEqual(@as(u64, 0), pair_serial_scratch.model_shaped_dispatches);
    try testing.expectEqual(@as(usize, 0), pair_serial_scratch.fallbacks);
    try testing.expectEqual(@as(usize, 0), pair_serial_scratch.rejects);
    try testing.expectEqual(
        separate_storage_telemetry.separate_gate_bytes +
            separate_storage_telemetry.separate_up_bytes,
        pair_serial_telemetry.pair_weight_bytes +
            pair_serial_telemetry.pair_scale_bytes,
    );

    // Same Pair image and executor, differing only in frame ownership. This is
    // the in-process exactness oracle for the fresh-process ABBA harness.
    var pair_materialized_telemetry: engine.generate.PairNibbleExecutionTelemetry = .{};
    const pair_materialized_tokens = try engine.generate.generate(
        testing.allocator,
        pair_mapped,
        &prompt,
        .{
            .max_new_tokens = 4,
            .num_threads = 1,
            .use_batch_prefill = false,
            .mlp_representation = .pair_nibble_required,
            .decode_frame_mode = .materialized_required,
            .pair_nibble_telemetry = &pair_materialized_telemetry,
        },
    );
    defer testing.allocator.free(pair_materialized_tokens);
    try testing.expectEqualSlices(u32, pair_serial_tokens, pair_materialized_tokens);
    try testing.expectEqual(
        @as(usize, 1),
        pair_materialized_telemetry.decode_frame_materialized_uses,
    );
    try testing.expectEqual(
        @as(usize, 0),
        pair_materialized_telemetry.decode_frame_compact_pair_uses,
    );
    try testing.expectEqual(
        pair_serial_telemetry.decode_frame_materialized_bytes,
        pair_materialized_telemetry.decode_frame_tensor_bytes,
    );
    try testing.expectEqual(
        @as(usize, 0),
        pair_materialized_telemetry.decode_frame_reclaimed_bytes,
    );
    try testing.expectEqual(
        pair_serial_telemetry.outputless_m1_dispatches,
        pair_materialized_telemetry.outputless_m1_dispatches,
    );

    // DecodeLane4 is one strict shared-weight M4 cohort, not four hidden M1
    // calls. Distinct prompts and stochastic seeds prove that token journals,
    // KV state, and full Xoshiro transitions remain lane-local while every
    // packed model stream is reused across four rows.
    const lane_prompts = [engine.decode_lane4.width][3]u32{
        .{ 1, 2, 3 },
        .{ 4, 5, 6 },
        .{ 7, 8, 9 },
        .{ 10, 11, 12 },
    };
    const stochastic_sampler: engine.sampling.SamplerConfig = .{
        .temperature = 0.85,
        .top_k = 17,
        .top_p = 0.9,
    };
    const stochastic_requests = [engine.decode_lane4.width]engine.decode_lane4.Request{
        .{
            .prompt = &lane_prompts[0],
            .max_new_tokens = 4,
            .sampler = stochastic_sampler,
            .seed = 0x1001,
        },
        .{
            .prompt = &lane_prompts[1],
            .max_new_tokens = 4,
            .sampler = stochastic_sampler,
            .seed = 0x2002,
        },
        .{
            .prompt = &lane_prompts[2],
            .max_new_tokens = 4,
            .sampler = stochastic_sampler,
            .seed = 0x3003,
        },
        .{
            .prompt = &lane_prompts[3],
            .max_new_tokens = 4,
            .sampler = stochastic_sampler,
            .seed = 0x4004,
        },
    };
    var stochastic_m1_states =
        [_]engine.generate.GenerationStateTelemetry{.{}} ** engine.decode_lane4.width;
    var stochastic_m1_tokens: [engine.decode_lane4.width][]u32 = undefined;
    var stochastic_m1_initialized: usize = 0;
    defer for (stochastic_m1_tokens[0..stochastic_m1_initialized]) |tokens|
        testing.allocator.free(tokens);
    for (
        stochastic_requests,
        &stochastic_m1_states,
        &stochastic_m1_tokens,
    ) |request, *state, *tokens| {
        tokens.* = try generatePairM1Oracle(pair_mapped, request, state);
        stochastic_m1_initialized += 1;
    }

    // Ordinary M1 exposes the same allocation-free claim used by its actual
    // admission plan. A strict prepared Pair request must commit that claim
    // byte-for-byte, pass at the exact host cap, and release it once.
    const strict_m1_request = stochastic_requests[0];
    const strict_m1_claim = try engine.generate.deriveResourceClaim(
        pair_mapped,
        strict_m1_request.prompt,
        .{
            .max_new_tokens = strict_m1_request.max_new_tokens,
            .eos_token = strict_m1_request.eos_token,
            .sampler = strict_m1_request.sampler,
            .seed = strict_m1_request.seed,
            .num_threads = 1,
            .use_batch_prefill = false,
            .mlp_representation = .pair_nibble_required,
            .decode_frame_mode = .compact_pair_required,
            .parallel_attention_min_context = null,
        },
    );
    const strict_m1_host_bytes = try strict_m1_claim.hostBytes();
    try testing.expect(strict_m1_host_bytes > 0);
    try testing.expectEqual(@as(u64, 1), strict_m1_claim.queue_slots);

    var strict_m1_slots = [_]engine.resource_bank.Slot{.{}} ** 1;
    var strict_m1_bank = try engine.resource_bank.Bank.init(
        &strict_m1_slots,
        .{
            .host_bytes = strict_m1_host_bytes,
            .queue_slots = 1,
        },
        0x4d31_434c_4149_4d01,
    );
    var strict_m1_resources: engine.generate.RequestResourceTelemetry = .{};
    var strict_m1_observer: CommitObserverContext = .{
        .bank = &strict_m1_bank,
        .reject = false,
    };
    const strict_m1_tokens = try engine.generate.generate(
        testing.allocator,
        pair_mapped,
        strict_m1_request.prompt,
        .{
            .max_new_tokens = strict_m1_request.max_new_tokens,
            .eos_token = strict_m1_request.eos_token,
            .sampler = strict_m1_request.sampler,
            .seed = strict_m1_request.seed,
            .num_threads = 1,
            .use_batch_prefill = false,
            .mlp_representation = .pair_nibble_required,
            .decode_frame_mode = .compact_pair_required,
            .parallel_attention_min_context = null,
            .request_resource_bank = &strict_m1_bank,
            .request_resource_telemetry = &strict_m1_resources,
            .resource_commit_observer = .{
                .context = &strict_m1_observer,
                .observe = CommitObserverContext.observe,
            },
        },
    );
    defer testing.allocator.free(strict_m1_tokens);
    try testing.expectEqualSlices(u32, stochastic_m1_tokens[0], strict_m1_tokens);
    try testing.expectEqual(@as(usize, 1), strict_m1_observer.calls);
    try testing.expect(std.meta.eql(
        strict_m1_claim,
        strict_m1_observer.receipt.?.claim,
    ));
    try testing.expectEqual(
        strict_m1_host_bytes,
        strict_m1_resources.host_limit_bytes,
    );
    try testing.expectEqual(
        strict_m1_host_bytes,
        strict_m1_resources.host_claim_bytes,
    );
    try testing.expectEqual(@as(u64, 1), strict_m1_resources.reservations);
    try testing.expectEqual(@as(u64, 1), strict_m1_resources.commits);
    try testing.expectEqual(@as(u64, 1), strict_m1_resources.releases);
    try testing.expect((try strict_m1_bank.snapshot()).used.isZero());

    // One byte below the public result rejects at Bank admission without
    // consulting the caller allocator or publishing a receipt.
    var strict_under_slots = [_]engine.resource_bank.Slot{.{}} ** 1;
    var strict_under_bank = try engine.resource_bank.Bank.init(
        &strict_under_slots,
        .{
            .host_bytes = strict_m1_host_bytes - 1,
            .queue_slots = 1,
        },
        0x4d31_434c_4149_4d02,
    );
    var strict_under_allocator = std.testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    try testing.expectError(
        engine.generate.GenerateError.ResourceBudgetExceeded,
        engine.generate.generate(
            strict_under_allocator.allocator(),
            pair_mapped,
            strict_m1_request.prompt,
            .{
                .max_new_tokens = strict_m1_request.max_new_tokens,
                .eos_token = strict_m1_request.eos_token,
                .sampler = strict_m1_request.sampler,
                .seed = strict_m1_request.seed,
                .num_threads = 1,
                .use_batch_prefill = false,
                .mlp_representation = .pair_nibble_required,
                .decode_frame_mode = .compact_pair_required,
                .parallel_attention_min_context = null,
                .request_resource_bank = &strict_under_bank,
            },
        ),
    );
    try testing.expectEqual(@as(usize, 0), strict_under_allocator.allocations);
    try testing.expect(!strict_under_allocator.has_induced_failure);
    const strict_under_snapshot = try strict_under_bank.snapshot();
    try testing.expectEqual(@as(u64, 1), strict_under_snapshot.rejected_capacity);
    try testing.expect(strict_under_snapshot.used.isZero());

    // M1's reachable cache ends at prompt + published - 1: the final output
    // token is never fed back through the graph. The 4,096-position campaign
    // boundary must therefore admit a 4,033-token prompt plus 64 outputs,
    // charge exactly 4,096 KV rows, and commit the public derived claim before
    // consulting the request allocator.
    const context_limit = engine.forward.max_attention_context;
    const boundary_new_tokens: usize = 64;
    const boundary_prompt_len = context_limit - boundary_new_tokens + 1;
    const context_probe_tokens = try testing.allocator.alloc(
        u32,
        context_limit + 1,
    );
    defer testing.allocator.free(context_probe_tokens);
    @memset(context_probe_tokens, 1);
    const boundary_prompt = context_probe_tokens[0..boundary_prompt_len];
    const boundary_claim = try engine.generate.deriveResourceClaim(
        pair_mapped,
        boundary_prompt,
        .{
            .max_new_tokens = boundary_new_tokens,
            .num_threads = 1,
            .use_batch_prefill = false,
            .mlp_representation = .pair_nibble_required,
            .decode_frame_mode = .compact_pair_required,
            .parallel_attention_min_context = null,
        },
    );
    const boundary_kv_ledger = try engine.kv_cache.deriveLogicalLedger(
        pair_mapped.config.num_layers,
        pair_mapped.config.num_kv_heads * pair_mapped.config.head_dim,
        context_limit,
    );
    try testing.expectEqual(
        @as(u64, @intCast(boundary_kv_ledger.allocation_payload_bytes)),
        boundary_claim.kv_bytes,
    );

    var boundary_slots = [_]engine.resource_bank.Slot{.{}} ** 1;
    var boundary_bank = try engine.resource_bank.Bank.init(
        &boundary_slots,
        .{
            .host_bytes = try boundary_claim.hostBytes(),
            .queue_slots = 1,
        },
        0x4d31_434f_4e54_5801,
    );
    var boundary_resources: engine.generate.RequestResourceTelemetry = .{};
    var boundary_observer: CommitObserverContext = .{
        .bank = &boundary_bank,
        .reject = true,
    };
    var boundary_allocator = std.testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    try testing.expectError(
        engine.generate.GenerateError.ResourceCommitObserverRejected,
        engine.generate.generate(
            boundary_allocator.allocator(),
            pair_mapped,
            boundary_prompt,
            .{
                .max_new_tokens = boundary_new_tokens,
                .num_threads = 1,
                .use_batch_prefill = false,
                .mlp_representation = .pair_nibble_required,
                .decode_frame_mode = .compact_pair_required,
                .parallel_attention_min_context = null,
                .request_resource_bank = &boundary_bank,
                .request_resource_telemetry = &boundary_resources,
                .resource_commit_observer = .{
                    .context = &boundary_observer,
                    .observe = CommitObserverContext.observe,
                },
            },
        ),
    );
    try testing.expectEqual(@as(usize, 1), boundary_observer.calls);
    try testing.expect(std.meta.eql(
        boundary_claim,
        boundary_observer.receipt.?.claim,
    ));
    try testing.expectEqual(@as(usize, 0), boundary_allocator.allocations);
    try testing.expect(!boundary_allocator.has_induced_failure);
    try testing.expectEqual(@as(u64, 1), boundary_resources.reservations);
    try testing.expectEqual(@as(u64, 1), boundary_resources.commits);
    try testing.expectEqual(@as(u64, 1), boundary_resources.releases);
    const boundary_snapshot = try boundary_bank.snapshot();
    try testing.expect(boundary_snapshot.used.isZero());
    try testing.expectEqual(@as(u64, 1), boundary_snapshot.successful_commits);
    try testing.expectEqual(@as(u64, 1), boundary_snapshot.releases);

    // One additional prompt row reaches 4,097 positions and must fail during
    // planning: no reservation, callback, or caller allocation is permitted.
    const too_long_prompt = context_probe_tokens[0 .. boundary_prompt_len + 1];
    try testing.expectError(
        engine.generate.GenerateError.ContextTooLong,
        engine.generate.deriveResourceClaim(
            pair_mapped,
            too_long_prompt,
            .{
                .max_new_tokens = boundary_new_tokens,
                .num_threads = 1,
                .use_batch_prefill = false,
                .mlp_representation = .pair_nibble_required,
                .decode_frame_mode = .compact_pair_required,
                .parallel_attention_min_context = null,
            },
        ),
    );
    var too_long_slots = [_]engine.resource_bank.Slot{.{}} ** 1;
    var too_long_bank = try engine.resource_bank.Bank.init(
        &too_long_slots,
        .{},
        0x4d31_434f_4e54_5802,
    );
    var too_long_observer: CommitObserverContext = .{
        .bank = &too_long_bank,
        .reject = true,
    };
    var too_long_allocator = std.testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    try testing.expectError(
        engine.generate.GenerateError.ContextTooLong,
        engine.generate.generate(
            too_long_allocator.allocator(),
            pair_mapped,
            too_long_prompt,
            .{
                .max_new_tokens = boundary_new_tokens,
                .num_threads = 1,
                .use_batch_prefill = false,
                .mlp_representation = .pair_nibble_required,
                .decode_frame_mode = .compact_pair_required,
                .parallel_attention_min_context = null,
                .request_resource_bank = &too_long_bank,
                .resource_commit_observer = .{
                    .context = &too_long_observer,
                    .observe = CommitObserverContext.observe,
                },
            },
        ),
    );
    try testing.expectEqual(@as(usize, 0), too_long_observer.calls);
    try testing.expectEqual(@as(usize, 0), too_long_allocator.allocations);
    try testing.expect(!too_long_allocator.has_induced_failure);
    const too_long_snapshot = try too_long_bank.snapshot();
    try testing.expect(too_long_snapshot.used.isZero());
    try testing.expectEqual(@as(u64, 0), too_long_snapshot.successful_reservations);

    // Zero-token requests still accept a prompt exactly at the context limit,
    // return the canonical empty completion state, and expose no ResourceBank
    // claim. A longer prompt and arithmetic overflow remain fail-closed before
    // the first allocator call.
    var boundary_zero_state: engine.generate.GenerationStateTelemetry = .{};
    const zero_tokens = try engine.generate.generate(
        testing.allocator,
        pair_mapped,
        context_probe_tokens[0..context_limit],
        .{
            .max_new_tokens = 0,
            .mlp_representation = .pair_nibble_required,
            .decode_frame_mode = .compact_pair_required,
            .generation_state_telemetry = &boundary_zero_state,
        },
    );
    defer testing.allocator.free(zero_tokens);
    try testing.expectEqual(@as(usize, 0), zero_tokens.len);
    try testing.expect(boundary_zero_state.complete);
    try testing.expectEqual(@as(usize, 0), boundary_zero_state.kv_positions);
    try testing.expectEqual(@as(usize, 0), boundary_zero_state.published_tokens);
    try testing.expectEqual(@as(usize, 0), boundary_zero_state.sampling_calls);
    try testing.expectError(
        engine.generate.GenerateError.ResourceAdmissionUnavailable,
        engine.generate.deriveResourceClaim(
            pair_mapped,
            context_probe_tokens[0..context_limit],
            .{
                .max_new_tokens = 0,
                .mlp_representation = .pair_nibble_required,
                .decode_frame_mode = .compact_pair_required,
            },
        ),
    );
    var zero_too_long_allocator = std.testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    try testing.expectError(
        engine.generate.GenerateError.ContextTooLong,
        engine.generate.generate(
            zero_too_long_allocator.allocator(),
            pair_mapped,
            context_probe_tokens,
            .{
                .max_new_tokens = 0,
                .mlp_representation = .pair_nibble_required,
                .decode_frame_mode = .compact_pair_required,
            },
        ),
    );
    try testing.expectEqual(@as(usize, 0), zero_too_long_allocator.allocations);
    try testing.expect(!zero_too_long_allocator.has_induced_failure);

    try testing.expectError(
        engine.generate.GenerateError.ContextTooLong,
        engine.generate.deriveResourceClaim(
            pair_mapped,
            strict_m1_request.prompt,
            .{
                .max_new_tokens = std.math.maxInt(usize),
                .mlp_representation = .pair_nibble_required,
                .decode_frame_mode = .compact_pair_required,
            },
        ),
    );
    var overflow_allocator = std.testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    try testing.expectError(
        engine.generate.GenerateError.ContextTooLong,
        engine.generate.generate(
            overflow_allocator.allocator(),
            pair_mapped,
            strict_m1_request.prompt,
            .{
                .max_new_tokens = std.math.maxInt(usize),
                .mlp_representation = .pair_nibble_required,
                .decode_frame_mode = .compact_pair_required,
            },
        ),
    );
    try testing.expectEqual(@as(usize, 0), overflow_allocator.allocations);
    try testing.expect(!overflow_allocator.has_induced_failure);

    // A required Pair prefill capsule cannot coexist with disabled batch
    // prefill. Public derivation and execution reject the same strict option
    // set before the first caller allocation.
    try testing.expectError(
        engine.generate.GenerateError.BatchPrefillUnavailable,
        engine.generate.deriveResourceClaim(
            pair_mapped,
            strict_m1_request.prompt,
            .{
                .max_new_tokens = strict_m1_request.max_new_tokens,
                .num_threads = 1,
                .use_batch_prefill = false,
                .mlp_representation = .pair_nibble_required,
                .decode_frame_mode = .compact_pair_required,
                .pair_prefill_frame_mode = .compact_64_required,
            },
        ),
    );
    var invalid_strict_allocator = std.testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    try testing.expectError(
        engine.generate.GenerateError.BatchPrefillUnavailable,
        engine.generate.generate(
            invalid_strict_allocator.allocator(),
            pair_mapped,
            strict_m1_request.prompt,
            .{
                .max_new_tokens = strict_m1_request.max_new_tokens,
                .num_threads = 1,
                .use_batch_prefill = false,
                .mlp_representation = .pair_nibble_required,
                .decode_frame_mode = .compact_pair_required,
                .pair_prefill_frame_mode = .compact_64_required,
            },
        ),
    );
    try testing.expectEqual(@as(usize, 0), invalid_strict_allocator.allocations);
    try testing.expect(!invalid_strict_allocator.has_induced_failure);

    // Resource admission is part of the strict ABI, not optional telemetry.
    // A valid cohort without a shared authority must fail before allocation.
    var missing_bank_telemetry: engine.decode_lane4.Telemetry = .{
        .admitted_cohorts = 99,
    };
    var missing_bank_allocator = std.testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    try testing.expectError(
        engine.generate.GenerateError.ResourceAdmissionUnavailable,
        engine.decode_lane4.generate(
            missing_bank_allocator.allocator(),
            pair_mapped,
            stochastic_requests,
            .{
                .num_threads = 4,
                .telemetry = &missing_bank_telemetry,
            },
        ),
    );
    try testing.expectEqual(@as(usize, 0), missing_bank_allocator.allocations);
    try testing.expect(!missing_bank_allocator.has_induced_failure);
    try testing.expectEqual(@as(usize, 0), missing_bank_telemetry.admitted_cohorts);

    var cohort_slots = [_]engine.resource_bank.Slot{.{}} ** 1;
    var cohort_bank = try engine.resource_bank.Bank.init(
        &cohort_slots,
        .{},
        0x4c34_5445_5354_0001,
    );
    var cohort_resources: engine.generate.RequestResourceTelemetry = .{};
    var cohort_telemetry: engine.decode_lane4.Telemetry = .{};
    var cohort_token_events: TokenPublicationContext = .{};
    var cohort_result = try engine.decode_lane4.generate(
        testing.allocator,
        pair_mapped,
        stochastic_requests,
        .{
            .num_threads = 4,
            .request_resource_bank = &cohort_bank,
            .resource_telemetry = &cohort_resources,
            .token_publication_observer = .{
                .logical_request_index = 99,
                .context = &cohort_token_events,
                .observe = TokenPublicationContext.observe,
            },
            .telemetry = &cohort_telemetry,
        },
    );
    defer cohort_result.deinit();
    for (0..engine.decode_lane4.width) |lane| {
        try testing.expectEqualSlices(
            u32,
            stochastic_m1_tokens[lane],
            cohort_result.tokens(lane),
        );
        try testing.expectEqualDeep(
            stochastic_m1_states[lane],
            cohort_telemetry.lane_states[lane],
        );
        try testing.expect(stochastic_m1_states[lane].complete);
        try testing.expectEqual(
            @as(usize, 4),
            stochastic_m1_states[lane].published_tokens,
        );
        try testing.expectEqual(
            @as(usize, 4),
            stochastic_m1_states[lane].sampling_calls,
        );
        try testing.expectEqual(
            lane_prompts[lane].len + 3,
            stochastic_m1_states[lane].kv_positions,
        );
    }
    try testing.expectEqual(@as(usize, 16), cohort_token_events.calls);
    for (cohort_token_events.events[0..cohort_token_events.calls], 0..) |event, index| {
        const step = index / engine.decode_lane4.width;
        const lane = index % engine.decode_lane4.width;
        try testing.expectEqual(@as(u32, @intCast(lane)), event.logical_request_index);
        try testing.expectEqual(@as(u64, @intCast(step)), event.step_index);
        try testing.expectEqual(cohort_result.tokens(lane)[step], event.token_id);
        try testing.expectEqual(step == 3, event.terminal);
    }
    try testing.expectEqual(engine.decode_lane4.abi, cohort_telemetry.abi_version);
    try testing.expectEqual(@as(usize, 1), cohort_telemetry.admitted_cohorts);
    try testing.expectEqual(engine.decode_lane4.width, cohort_telemetry.cohort_width);
    try testing.expectEqual(@as(usize, 4), cohort_telemetry.thread_participants);
    try testing.expect(cohort_telemetry.frame_payload_bytes > 0);
    try testing.expectEqual(@as(usize, 6), cohort_telemetry.token_graphs);
    try testing.expectEqual(@as(usize, 24), cohort_telemetry.layer_m4_graphs);
    try testing.expectEqual(@as(usize, 120), cohort_telemetry.projection_m4_dispatches);
    try testing.expectEqual(@as(usize, 72), cohort_telemetry.qkv_projection_dispatches);
    try testing.expectEqual(@as(usize, 24), cohort_telemetry.qkv_activation_quantizations);
    try testing.expectEqual(@as(usize, 48), cohort_telemetry.qkv_quantization_reuses);
    try testing.expectEqual(
        @as(usize, 52),
        cohort_telemetry.weight_stationary_norm_dispatches,
    );
    try testing.expectEqual(
        @as(usize, 24),
        cohort_telemetry.lane_parallel_attention_dispatches,
    );
    try testing.expectEqual(
        @as(usize, 96),
        cohort_telemetry.lane_parallel_attention_tasks,
    );
    try testing.expectEqual(@as(usize, 24), cohort_telemetry.pair_m4_dispatches);
    try testing.expectEqual(@as(usize, 4), cohort_telemetry.lm_head_m4_dispatches);
    try testing.expectEqual(@as(usize, 24), cohort_telemetry.active_lane_steps);
    try testing.expectEqual(@as(usize, 0), cohort_telemetry.padded_lane_steps);
    try testing.expectEqual(@as(usize, 0), cohort_telemetry.fallbacks);
    try testing.expectEqual(
        @as(usize, 1),
        cohort_telemetry.state_hash_parallel_dispatches,
    );
    try testing.expectEqual(
        engine.decode_lane4.width,
        cohort_telemetry.state_hash_tasks,
    );
    try testing.expectEqual(
        @as(usize, 0),
        cohort_telemetry.state_hash_enqueue_rejects,
    );

    // Rebind the same immutable Pair image to a valid long-context GQA
    // topology. K/V use the first two eight-row heads from the original
    // 64-row projection while Q/O and every MLP stream remain shared by
    // value. This crosses the 64-token boundary and requires every token,
    // KV digest, output digest, and full Xoshiro state to match four
    // independent serial M1 executions exactly.
    const gqa_prompt_len: usize = 65;
    const gqa_max_new_tokens: usize = 3;
    const gqa_num_heads: usize = 8;
    const gqa_num_kv_heads: usize = 2;
    const gqa_head_dim: usize = 8;
    const gqa_kv_dim = gqa_num_kv_heads * gqa_head_dim;
    const gqa_kv_elements = gqa_kv_dim * DIM;
    try testing.expectEqual(@as(usize, 16), gqa_kv_dim);
    try testing.expectEqual(@as(usize, 16 * DIM), gqa_kv_elements);
    var gqa_layers: [NUM_LAYERS]engine.forward.LayerWeights = undefined;
    @memcpy(gqa_layers[0..], pair_mapped.layers);
    for (&gqa_layers) |*layer| {
        layer.wk = &.{};
        layer.wv = &.{};
        layer.wk_f16 = &.{};
        layer.wv_f16 = &.{};
        layer.bq = &.{};
        layer.bk = &.{};
        layer.bv = &.{};
        layer.bo = &.{};
        layer.wk_int4 = try packedInt4Prefix(
            layer.wk_int4.?,
            gqa_kv_elements,
        );
        layer.wv_int4 = try packedInt4Prefix(
            layer.wv_int4.?,
            gqa_kv_elements,
        );
    }
    var gqa_model = pair_mapped;
    gqa_model.config.num_heads = gqa_num_heads;
    gqa_model.config.num_kv_heads = gqa_num_kv_heads;
    gqa_model.config.head_dim = gqa_head_dim;
    gqa_model.layers = gqa_layers[0..];

    var gqa_prompts: [engine.decode_lane4.width][gqa_prompt_len]u32 = undefined;
    for (&gqa_prompts, 0..) |*lane_prompt, lane| {
        for (lane_prompt, 0..) |*token, position| {
            token.* = @intCast(
                (lane * 31 + position * 17 + 1) % (VOCAB - 1) + 1,
            );
        }
    }
    const gqa_requests = [engine.decode_lane4.width]engine.decode_lane4.Request{
        .{
            .prompt = &gqa_prompts[0],
            .max_new_tokens = gqa_max_new_tokens,
            .sampler = stochastic_sampler,
            .seed = 0x1111_aaaa,
        },
        .{
            .prompt = &gqa_prompts[1],
            .max_new_tokens = gqa_max_new_tokens,
            .sampler = stochastic_sampler,
            .seed = 0x2222_bbbb,
        },
        .{
            .prompt = &gqa_prompts[2],
            .max_new_tokens = gqa_max_new_tokens,
            .sampler = stochastic_sampler,
            .seed = 0x3333_cccc,
        },
        .{
            .prompt = &gqa_prompts[3],
            .max_new_tokens = gqa_max_new_tokens,
            .sampler = stochastic_sampler,
            .seed = 0x4444_dddd,
        },
    };
    var gqa_m1_states =
        [_]engine.generate.GenerationStateTelemetry{.{}} ** engine.decode_lane4.width;
    var gqa_m1_tokens: [engine.decode_lane4.width][]u32 = undefined;
    var gqa_m1_initialized: usize = 0;
    defer for (gqa_m1_tokens[0..gqa_m1_initialized]) |tokens|
        testing.allocator.free(tokens);
    for (gqa_requests, &gqa_m1_states, &gqa_m1_tokens) |request, *state, *tokens| {
        tokens.* = try generatePairM1Oracle(gqa_model, request, state);
        gqa_m1_initialized += 1;
    }

    var gqa_telemetry: engine.decode_lane4.Telemetry = .{};
    var gqa_result = try engine.decode_lane4.generate(
        testing.allocator,
        gqa_model,
        gqa_requests,
        .{
            .num_threads = 4,
            .request_resource_bank = &cohort_bank,
            .telemetry = &gqa_telemetry,
        },
    );
    defer gqa_result.deinit();
    for (0..engine.decode_lane4.width) |lane| {
        const expected_state = gqa_m1_states[lane];
        const actual_state = gqa_telemetry.lane_states[lane];
        try testing.expectEqualSlices(
            u32,
            gqa_m1_tokens[lane],
            gqa_result.tokens(lane),
        );
        try testing.expectEqualDeep(expected_state, actual_state);
        try testing.expectEqualSlices(
            u8,
            &expected_state.kv_sha256,
            &actual_state.kv_sha256,
        );
        try testing.expectEqualSlices(
            u8,
            &expected_state.output_sha256,
            &actual_state.output_sha256,
        );
        try testing.expectEqualSlices(
            u64,
            &expected_state.rng_state,
            &actual_state.rng_state,
        );
        try testing.expect(expected_state.complete);
        try testing.expectEqual(gqa_max_new_tokens, expected_state.published_tokens);
        try testing.expectEqual(gqa_max_new_tokens, expected_state.sampling_calls);
        try testing.expectEqual(
            gqa_prompt_len + gqa_max_new_tokens - 1,
            expected_state.kv_positions,
        );
    }
    const gqa_token_graphs = gqa_prompt_len + gqa_max_new_tokens - 1;
    const gqa_attention_dispatches = gqa_token_graphs * NUM_LAYERS;
    try testing.expectEqual(gqa_token_graphs, gqa_telemetry.token_graphs);
    try testing.expectEqual(
        gqa_attention_dispatches,
        gqa_telemetry.lane_parallel_attention_dispatches,
    );
    try testing.expectEqual(
        gqa_attention_dispatches * engine.decode_lane4.width,
        gqa_telemetry.lane_parallel_attention_tasks,
    );
    try testing.expectEqual(
        @as(usize, 0),
        gqa_telemetry.lane_attention_enqueue_rejects,
    );
    try testing.expectEqual(@as(usize, 0), gqa_telemetry.fallbacks);

    // Scheduling order is not semantic state. Move every logical request to a
    // different physical lane, invert the permutation, and require both token
    // journals and complete state receipts to remain bit-identical.
    const lane_permutation = [engine.decode_lane4.width]usize{ 2, 0, 3, 1 };
    var inverse_lane_permutation =
        [_]usize{std.math.maxInt(usize)} ** engine.decode_lane4.width;
    var permuted_requests: [engine.decode_lane4.width]engine.decode_lane4.Request = undefined;
    for (lane_permutation, 0..) |original_lane, physical_lane| {
        try testing.expect(original_lane < engine.decode_lane4.width);
        try testing.expectEqual(
            std.math.maxInt(usize),
            inverse_lane_permutation[original_lane],
        );
        inverse_lane_permutation[original_lane] = physical_lane;
        permuted_requests[physical_lane] = stochastic_requests[original_lane];
    }
    var permutation_telemetry: engine.decode_lane4.Telemetry = .{};
    var permutation_result = try engine.decode_lane4.generate(
        testing.allocator,
        pair_mapped,
        permuted_requests,
        .{
            .num_threads = 4,
            .request_resource_bank = &cohort_bank,
            .telemetry = &permutation_telemetry,
        },
    );
    defer permutation_result.deinit();
    for (0..engine.decode_lane4.width) |original_lane| {
        const physical_lane = inverse_lane_permutation[original_lane];
        try testing.expect(physical_lane != original_lane);
        try testing.expectEqualSlices(
            u32,
            cohort_result.tokens(original_lane),
            permutation_result.tokens(physical_lane),
        );
        try testing.expectEqualDeep(
            cohort_telemetry.lane_states[original_lane],
            permutation_telemetry.lane_states[physical_lane],
        );
    }
    try testing.expectEqual(
        cohort_telemetry.abi_version,
        permutation_telemetry.abi_version,
    );
    try testing.expectEqual(
        cohort_telemetry.admitted_cohorts,
        permutation_telemetry.admitted_cohorts,
    );
    try testing.expectEqual(
        cohort_telemetry.cohort_width,
        permutation_telemetry.cohort_width,
    );
    try testing.expectEqual(
        cohort_telemetry.thread_participants,
        permutation_telemetry.thread_participants,
    );
    try testing.expectEqual(
        cohort_telemetry.frame_payload_bytes,
        permutation_telemetry.frame_payload_bytes,
    );
    try testing.expectEqual(
        cohort_telemetry.layer_m4_graphs,
        permutation_telemetry.layer_m4_graphs,
    );
    try testing.expectEqual(
        cohort_telemetry.projection_m4_dispatches,
        permutation_telemetry.projection_m4_dispatches,
    );
    try testing.expectEqual(
        cohort_telemetry.token_graphs,
        permutation_telemetry.token_graphs,
    );
    try testing.expectEqual(
        cohort_telemetry.qkv_projection_dispatches,
        permutation_telemetry.qkv_projection_dispatches,
    );
    try testing.expectEqual(
        cohort_telemetry.qkv_activation_quantizations,
        permutation_telemetry.qkv_activation_quantizations,
    );
    try testing.expectEqual(
        cohort_telemetry.qkv_quantization_reuses,
        permutation_telemetry.qkv_quantization_reuses,
    );
    try testing.expectEqual(
        cohort_telemetry.weight_stationary_norm_dispatches,
        permutation_telemetry.weight_stationary_norm_dispatches,
    );
    try testing.expectEqual(
        cohort_telemetry.lane_parallel_attention_dispatches,
        permutation_telemetry.lane_parallel_attention_dispatches,
    );
    try testing.expectEqual(
        cohort_telemetry.lane_parallel_attention_tasks,
        permutation_telemetry.lane_parallel_attention_tasks,
    );
    try testing.expectEqual(
        cohort_telemetry.pair_m4_dispatches,
        permutation_telemetry.pair_m4_dispatches,
    );
    try testing.expectEqual(
        cohort_telemetry.lm_head_m4_dispatches,
        permutation_telemetry.lm_head_m4_dispatches,
    );
    try testing.expectEqual(
        cohort_telemetry.active_lane_steps,
        permutation_telemetry.active_lane_steps,
    );
    try testing.expectEqual(
        cohort_telemetry.padded_lane_steps,
        permutation_telemetry.padded_lane_steps,
    );
    try testing.expectEqual(@as(usize, 0), permutation_telemetry.fallbacks);

    // The public allocation-free derivation and the committed receipt must
    // describe the same complete cohort claim. One bank slot owns the cohort;
    // its resource dimension nevertheless charges all four logical queue slots.
    const cohort_claim = try engine.decode_lane4.deriveResourceClaim(
        pair_mapped,
        stochastic_requests,
        .{ .num_threads = 4 },
    );
    const cohort_host_bytes = try cohort_claim.hostBytes();
    try testing.expect(cohort_host_bytes > 0);
    try testing.expectEqual(cohort_host_bytes, cohort_resources.host_claim_bytes);
    try testing.expectEqual(cohort_claim.kv_bytes, cohort_resources.kv_bytes);
    try testing.expectEqual(
        cohort_claim.activation_bytes,
        cohort_resources.activation_bytes,
    );
    try testing.expectEqual(cohort_claim.partial_bytes, cohort_resources.partial_bytes);
    try testing.expectEqual(cohort_claim.logits_bytes, cohort_resources.logits_bytes);
    try testing.expectEqual(
        cohort_claim.output_journal_bytes,
        cohort_resources.output_journal_bytes,
    );
    try testing.expectEqual(cohort_claim.staging_bytes, cohort_resources.staging_bytes);
    try testing.expectEqual(@as(u64, 4), cohort_resources.queue_slots);
    try testing.expect(cohort_resources.owner_key != 0);
    try testing.expectEqual(@as(u32, 0), cohort_resources.receipt_slot_index);
    try testing.expectEqual(@as(u64, 1), cohort_resources.receipt_generation);
    try testing.expect(cohort_resources.receipt_integrity != 0);
    try testing.expectEqual(cohort_host_bytes, cohort_resources.peak_host_bytes);
    try testing.expectEqual(@as(u64, 1), cohort_resources.reservations);
    try testing.expectEqual(@as(u64, 1), cohort_resources.commits);
    try testing.expectEqual(@as(u64, 1), cohort_resources.releases);
    try testing.expectEqual(@as(usize, 0), cohort_resources.release_failures);
    try testing.expect((try cohort_bank.snapshot()).used.isZero());

    // The derived maximum is an exact hard boundary, not an estimate: it must
    // pass at equality and preserve both numerical and state receipts.
    var exact_slots = [_]engine.resource_bank.Slot{.{}} ** 1;
    var exact_bank = try engine.resource_bank.Bank.init(
        &exact_slots,
        .{
            .host_bytes = cohort_host_bytes,
            .queue_slots = engine.decode_lane4.width,
        },
        0x4c34_5445_5354_0002,
    );
    var exact_resources: engine.generate.RequestResourceTelemetry = .{};
    var exact_telemetry: engine.decode_lane4.Telemetry = .{};
    var exact_result = try engine.decode_lane4.generate(
        testing.allocator,
        pair_mapped,
        stochastic_requests,
        .{
            .num_threads = 4,
            .request_resource_bank = &exact_bank,
            .resource_telemetry = &exact_resources,
            .telemetry = &exact_telemetry,
        },
    );
    defer exact_result.deinit();
    for (0..engine.decode_lane4.width) |lane| {
        try testing.expectEqualSlices(
            u32,
            stochastic_m1_tokens[lane],
            exact_result.tokens(lane),
        );
        try testing.expectEqualDeep(
            stochastic_m1_states[lane],
            exact_telemetry.lane_states[lane],
        );
    }
    try testing.expectEqual(cohort_host_bytes, exact_resources.host_limit_bytes);
    try testing.expectEqual(cohort_host_bytes, exact_resources.peak_host_bytes);
    try testing.expectEqual(@as(u64, 1), exact_resources.reservations);
    try testing.expectEqual(@as(u64, 1), exact_resources.commits);
    try testing.expectEqual(@as(u64, 1), exact_resources.releases);
    try testing.expect((try exact_bank.snapshot()).used.isZero());

    // One byte below that same derived claim rejects before a reservation can
    // commit and leaves the shared authority entirely reusable.
    var under_slots = [_]engine.resource_bank.Slot{.{}} ** 1;
    var under_bank = try engine.resource_bank.Bank.init(
        &under_slots,
        .{
            .host_bytes = cohort_host_bytes - 1,
            .queue_slots = engine.decode_lane4.width,
        },
        0x4c34_5445_5354_0003,
    );
    var under_resources: engine.generate.RequestResourceTelemetry = .{};
    try testing.expectError(
        engine.generate.GenerateError.ResourceBudgetExceeded,
        engine.decode_lane4.generate(
            testing.allocator,
            pair_mapped,
            stochastic_requests,
            .{
                .num_threads = 4,
                .request_resource_bank = &under_bank,
                .resource_telemetry = &under_resources,
            },
        ),
    );
    try testing.expectEqual(cohort_host_bytes, under_resources.host_claim_bytes);
    try testing.expectEqual(@as(u64, 0), under_resources.reservations);
    try testing.expectEqual(@as(u64, 0), under_resources.commits);
    try testing.expectEqual(@as(u64, 0), under_resources.releases);
    try testing.expectEqual(@as(u64, 1), under_resources.capacity_rejects);
    try testing.expectEqual(@as(usize, 0), under_resources.active_reservations);
    try testing.expectEqual(@as(usize, 0), under_resources.committed_receipts);
    try testing.expect((try under_bank.snapshot()).used.isZero());

    // The shared post-commit observer sees the complete committed B4 receipt
    // and live Bank snapshot before the first allocator use. Rejection is
    // fail-closed and the already-installed sole defer releases exactly once.
    var observer_slots = [_]engine.resource_bank.Slot{.{}} ** 1;
    var observer_bank = try engine.resource_bank.Bank.init(
        &observer_slots,
        .{},
        0x4c34_5445_5354_0006,
    );
    var observer_context: CommitObserverContext = .{
        .bank = &observer_bank,
    };
    var observer_resources: engine.generate.RequestResourceTelemetry = .{};
    var observer_allocator = std.testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    try testing.expectError(
        engine.generate.GenerateError.ResourceCommitObserverRejected,
        engine.decode_lane4.generate(
            observer_allocator.allocator(),
            pair_mapped,
            stochastic_requests,
            .{
                .num_threads = 4,
                .request_resource_bank = &observer_bank,
                .resource_telemetry = &observer_resources,
                .resource_commit_observer = .{
                    .context = &observer_context,
                    .observe = CommitObserverContext.observe,
                },
            },
        ),
    );
    try testing.expectEqual(@as(usize, 1), observer_context.calls);
    try testing.expectEqual(@as(usize, 0), observer_allocator.allocations);
    try testing.expect(!observer_allocator.has_induced_failure);
    try testing.expectEqual(
        engine.generate.resource_commit_observer_abi,
        observer_context.evidence_abi,
    );
    try testing.expectEqual(
        engine.resource_bank.abi,
        observer_context.resource_bank_abi,
    );
    try testing.expectEqual(@as(usize, 1), observer_context.committed_receipts_at_callback);
    try testing.expectEqual(
        @as(u64, engine.decode_lane4.width),
        observer_context.queue_slots_at_callback,
    );
    try testing.expect(std.meta.eql(
        cohort_claim,
        observer_context.receipt.?.claim,
    ));
    try testing.expectEqual(
        observer_resources.owner_key,
        observer_context.receipt.?.owner_key,
    );
    try testing.expectEqual(@as(u64, 1), observer_resources.reservations);
    try testing.expectEqual(@as(u64, 1), observer_resources.commits);
    try testing.expectEqual(@as(u64, 1), observer_resources.releases);
    try testing.expect((try observer_bank.snapshot()).used.isZero());

    // Token publication evidence is equally fail-closed. An invalid ABI is a
    // preflight rejection; a callback rejection after the first journal write
    // unwinds all request allocations and the one committed cohort receipt.
    var invalid_token_context: TokenPublicationContext = .{};
    var invalid_token_allocator = std.testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    try testing.expectError(
        engine.generate.GenerateError.TokenPublicationObserverRejected,
        engine.decode_lane4.generate(
            invalid_token_allocator.allocator(),
            pair_mapped,
            stochastic_requests,
            .{
                .num_threads = 4,
                .request_resource_bank = &observer_bank,
                .token_publication_observer = .{
                    .abi = engine.generate.token_publication_observer_abi + 1,
                    .context = &invalid_token_context,
                    .observe = TokenPublicationContext.observe,
                },
            },
        ),
    );
    try testing.expectEqual(@as(usize, 0), invalid_token_context.calls);
    try testing.expectEqual(@as(usize, 0), invalid_token_allocator.allocations);
    try testing.expect(!invalid_token_allocator.has_induced_failure);
    try testing.expect((try observer_bank.snapshot()).used.isZero());

    var token_reject_slots = [_]engine.resource_bank.Slot{.{}} ** 1;
    var token_reject_bank = try engine.resource_bank.Bank.init(
        &token_reject_slots,
        .{},
        0x4c34_5445_5354_0007,
    );
    var token_reject_context: TokenPublicationContext = .{ .reject_at = 0 };
    var token_reject_resources: engine.generate.RequestResourceTelemetry = .{};
    try testing.expectError(
        engine.generate.GenerateError.TokenPublicationObserverRejected,
        engine.decode_lane4.generate(
            testing.allocator,
            pair_mapped,
            stochastic_requests,
            .{
                .num_threads = 4,
                .request_resource_bank = &token_reject_bank,
                .resource_telemetry = &token_reject_resources,
                .token_publication_observer = .{
                    .context = &token_reject_context,
                    .observe = TokenPublicationContext.observe,
                },
            },
        ),
    );
    try testing.expectEqual(@as(usize, 1), token_reject_context.calls);
    try testing.expectEqual(@as(u64, 1), token_reject_resources.reservations);
    try testing.expectEqual(@as(u64, 1), token_reject_resources.commits);
    try testing.expectEqual(@as(u64, 1), token_reject_resources.releases);
    try testing.expectEqual(@as(usize, 0), token_reject_resources.release_failures);
    try testing.expect((try token_reject_bank.snapshot()).used.isZero());

    // Admission precedes every request-allocator allocation. Even failure of
    // the first frame allocation after commit must release the cohort receipt.
    var oom_slots = [_]engine.resource_bank.Slot{.{}} ** 1;
    var oom_bank = try engine.resource_bank.Bank.init(
        &oom_slots,
        .{},
        0x4c34_5445_5354_0004,
    );
    var oom_resources: engine.generate.RequestResourceTelemetry = .{};
    var oom_allocator = std.testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    try testing.expectError(
        engine.generate.GenerateError.OutOfMemory,
        engine.decode_lane4.generate(
            oom_allocator.allocator(),
            pair_mapped,
            stochastic_requests,
            .{
                .num_threads = 4,
                .request_resource_bank = &oom_bank,
                .resource_telemetry = &oom_resources,
            },
        ),
    );
    try testing.expect(oom_allocator.has_induced_failure);
    try testing.expectEqual(@as(u64, 1), oom_resources.reservations);
    try testing.expectEqual(@as(u64, 1), oom_resources.commits);
    try testing.expectEqual(@as(u64, 1), oom_resources.releases);
    try testing.expectEqual(@as(usize, 0), oom_resources.release_failures);
    try testing.expect((try oom_bank.snapshot()).used.isZero());

    // A deterministic early EOS retires lane zero while the other three keep
    // the M4 cohort occupied. Its final receipt is recorded only after those
    // later steps, so exact agreement with the independent M1 oracle proves
    // that padded execution cannot mutate retired KV, RNG, or output state.
    const forced_sequences = [engine.decode_lane4.width][4]u32{
        .{ 17, 18, 19, 20 },
        .{ 21, 22, 23, 24 },
        .{ 25, 26, 27, 28 },
        .{ 29, 30, 31, 32 },
    };
    const early_requests = [engine.decode_lane4.width]engine.decode_lane4.Request{
        .{
            .prompt = &lane_prompts[0],
            .max_new_tokens = 4,
            .eos_token = forced_sequences[0][0],
            .seed = 0x5005,
            .forced_tokens = &forced_sequences[0],
        },
        .{
            .prompt = &lane_prompts[1],
            .max_new_tokens = 4,
            .seed = 0x6006,
            .forced_tokens = &forced_sequences[1],
        },
        .{
            .prompt = &lane_prompts[2],
            .max_new_tokens = 4,
            .seed = 0x7007,
            .forced_tokens = &forced_sequences[2],
        },
        .{
            .prompt = &lane_prompts[3],
            .max_new_tokens = 4,
            .seed = 0x8008,
            .forced_tokens = &forced_sequences[3],
        },
    };
    var early_m1_states =
        [_]engine.generate.GenerationStateTelemetry{.{}} ** engine.decode_lane4.width;
    var early_m1_tokens: [engine.decode_lane4.width][]u32 = undefined;
    var early_m1_initialized: usize = 0;
    defer for (early_m1_tokens[0..early_m1_initialized]) |tokens|
        testing.allocator.free(tokens);
    for (early_requests, &early_m1_states, &early_m1_tokens) |request, *state, *tokens| {
        tokens.* = try generatePairM1Oracle(pair_mapped, request, state);
        early_m1_initialized += 1;
    }
    var early_telemetry: engine.decode_lane4.Telemetry = .{};
    var early_token_events: TokenPublicationContext = .{};
    var early_result = try engine.decode_lane4.generate(
        testing.allocator,
        pair_mapped,
        early_requests,
        .{
            .num_threads = 4,
            .request_resource_bank = &cohort_bank,
            .token_publication_observer = .{
                .context = &early_token_events,
                .observe = TokenPublicationContext.observe,
            },
            .telemetry = &early_telemetry,
        },
    );
    defer early_result.deinit();
    for (0..engine.decode_lane4.width) |lane| {
        try testing.expectEqualSlices(
            u32,
            early_m1_tokens[lane],
            early_result.tokens(lane),
        );
        try testing.expectEqualDeep(
            early_m1_states[lane],
            early_telemetry.lane_states[lane],
        );
        try testing.expect(early_m1_states[lane].complete);
        try testing.expectEqual(
            @as(usize, 0),
            early_m1_states[lane].sampling_calls,
        );
    }
    try testing.expectEqual(@as(usize, 13), early_token_events.calls);
    var published_by_lane = [_]usize{0} ** engine.decode_lane4.width;
    for (early_token_events.events[0..early_token_events.calls]) |event| {
        const lane: usize = @intCast(event.logical_request_index);
        try testing.expect(lane < engine.decode_lane4.width);
        const step = published_by_lane[lane];
        try testing.expectEqual(@as(u64, @intCast(step)), event.step_index);
        try testing.expectEqual(early_result.tokens(lane)[step], event.token_id);
        try testing.expectEqual(
            step + 1 == early_result.tokens(lane).len,
            event.terminal,
        );
        published_by_lane[lane] += 1;
    }
    for (published_by_lane, 0..) |count, lane|
        try testing.expectEqual(early_result.tokens(lane).len, count);
    try testing.expectEqual(@as(usize, 1), early_result.tokens(0).len);
    try testing.expectEqual(forced_sequences[0][0], early_result.tokens(0)[0]);
    try testing.expectEqual(@as(usize, 1), early_m1_states[0].published_tokens);
    try testing.expectEqual(lane_prompts[0].len, early_m1_states[0].kv_positions);
    for (1..engine.decode_lane4.width) |lane| {
        try testing.expectEqual(@as(usize, 4), early_result.tokens(lane).len);
        try testing.expectEqual(@as(usize, 4), early_m1_states[lane].published_tokens);
        try testing.expectEqual(
            lane_prompts[lane].len + 3,
            early_m1_states[lane].kv_positions,
        );
    }
    try testing.expectEqual(@as(usize, 24), early_telemetry.layer_m4_graphs);
    try testing.expectEqual(@as(usize, 120), early_telemetry.projection_m4_dispatches);
    try testing.expectEqual(@as(usize, 6), early_telemetry.token_graphs);
    try testing.expectEqual(@as(usize, 72), early_telemetry.qkv_projection_dispatches);
    try testing.expectEqual(@as(usize, 24), early_telemetry.qkv_activation_quantizations);
    try testing.expectEqual(@as(usize, 48), early_telemetry.qkv_quantization_reuses);
    try testing.expectEqual(
        @as(usize, 52),
        early_telemetry.weight_stationary_norm_dispatches,
    );
    try testing.expectEqual(
        @as(usize, 24),
        early_telemetry.lane_parallel_attention_dispatches,
    );
    try testing.expectEqual(
        @as(usize, 84),
        early_telemetry.lane_parallel_attention_tasks,
    );
    try testing.expectEqual(@as(usize, 24), early_telemetry.pair_m4_dispatches);
    try testing.expectEqual(@as(usize, 4), early_telemetry.lm_head_m4_dispatches);
    try testing.expectEqual(@as(usize, 21), early_telemetry.active_lane_steps);
    try testing.expectEqual(@as(usize, 3), early_telemetry.padded_lane_steps);
    try testing.expectEqual(@as(usize, 0), early_telemetry.fallbacks);

    // Retire three lanes at the first publication so the remaining request
    // exercises the required serial attention tail. Prompt layers still
    // submit four jobs each; tail layers must submit none, while the surviving
    // lane remains exactly equal to its independent M1 arithmetic and receipt.
    var single_tail_requests = early_requests;
    for (0..(engine.decode_lane4.width - 1)) |lane|
        single_tail_requests[lane].eos_token = forced_sequences[lane][0];
    var single_tail_m1_states =
        [_]engine.generate.GenerationStateTelemetry{.{}} ** engine.decode_lane4.width;
    var single_tail_m1_tokens: [engine.decode_lane4.width][]u32 = undefined;
    var single_tail_m1_initialized: usize = 0;
    defer for (single_tail_m1_tokens[0..single_tail_m1_initialized]) |tokens|
        testing.allocator.free(tokens);
    for (
        single_tail_requests,
        &single_tail_m1_states,
        &single_tail_m1_tokens,
    ) |request, *state, *tokens| {
        tokens.* = try generatePairM1Oracle(pair_mapped, request, state);
        single_tail_m1_initialized += 1;
    }
    var single_tail_telemetry: engine.decode_lane4.Telemetry = .{};
    var single_tail_result = try engine.decode_lane4.generate(
        testing.allocator,
        pair_mapped,
        single_tail_requests,
        .{
            .num_threads = 4,
            .request_resource_bank = &cohort_bank,
            .telemetry = &single_tail_telemetry,
        },
    );
    defer single_tail_result.deinit();
    for (0..engine.decode_lane4.width) |lane| {
        try testing.expectEqualSlices(
            u32,
            single_tail_m1_tokens[lane],
            single_tail_result.tokens(lane),
        );
        try testing.expectEqualDeep(
            single_tail_m1_states[lane],
            single_tail_telemetry.lane_states[lane],
        );
    }
    for (0..(engine.decode_lane4.width - 1)) |lane| {
        try testing.expectEqual(@as(usize, 1), single_tail_result.tokens(lane).len);
        try testing.expectEqual(
            lane_prompts[lane].len,
            single_tail_m1_states[lane].kv_positions,
        );
    }
    try testing.expectEqual(@as(usize, 4), single_tail_result.tokens(3).len);
    try testing.expectEqual(
        lane_prompts[3].len + 3,
        single_tail_m1_states[3].kv_positions,
    );
    try testing.expectEqual(@as(usize, 24), single_tail_telemetry.layer_m4_graphs);
    try testing.expectEqual(@as(usize, 6), single_tail_telemetry.token_graphs);
    try testing.expectEqual(
        @as(usize, 72),
        single_tail_telemetry.qkv_projection_dispatches,
    );
    try testing.expectEqual(
        @as(usize, 12),
        single_tail_telemetry.lane_parallel_attention_dispatches,
    );
    try testing.expectEqual(
        @as(usize, 48),
        single_tail_telemetry.lane_parallel_attention_tasks,
    );
    try testing.expectEqual(
        @as(usize, 12),
        single_tail_telemetry.layer_m4_graphs -
            single_tail_telemetry.lane_parallel_attention_dispatches,
    );
    try testing.expectEqual(@as(usize, 15), single_tail_telemetry.active_lane_steps);
    try testing.expectEqual(@as(usize, 9), single_tail_telemetry.padded_lane_steps);
    try testing.expectEqual(@as(usize, 0), single_tail_telemetry.fallbacks);

    // Malformed cohorts fail before any request allocation. Seed telemetry
    // with nonzero values to prove it is reset before strict preflight and that
    // rejection never records an admission, dispatch, or fallback.
    var unequal_requests = stochastic_requests;
    unequal_requests[3].prompt = lane_prompts[3][0..2];
    var unequal_telemetry: engine.decode_lane4.Telemetry = .{
        .admitted_cohorts = 99,
        .token_graphs = 99,
        .qkv_projection_dispatches = 99,
        .lane_parallel_attention_dispatches = 99,
        .lane_parallel_attention_tasks = 99,
        .fallbacks = 99,
    };
    var unequal_allocator = std.testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    try testing.expectError(
        engine.generate.GenerateError.ShapeMismatch,
        engine.decode_lane4.generate(
            unequal_allocator.allocator(),
            pair_mapped,
            unequal_requests,
            .{
                .num_threads = 4,
                .telemetry = &unequal_telemetry,
            },
        ),
    );
    try testing.expectEqual(@as(usize, 0), unequal_allocator.allocations);
    try testing.expect(!unequal_allocator.has_induced_failure);
    try testing.expectEqual(@as(usize, 0), unequal_telemetry.admitted_cohorts);
    try testing.expectEqual(@as(usize, 0), unequal_telemetry.token_graphs);
    try testing.expectEqual(@as(usize, 0), unequal_telemetry.layer_m4_graphs);
    try testing.expectEqual(@as(usize, 0), unequal_telemetry.projection_m4_dispatches);
    try testing.expectEqual(
        @as(usize, 0),
        unequal_telemetry.qkv_projection_dispatches,
    );
    try testing.expectEqual(
        @as(usize, 0),
        unequal_telemetry.lane_parallel_attention_dispatches,
    );
    try testing.expectEqual(
        @as(usize, 0),
        unequal_telemetry.lane_parallel_attention_tasks,
    );
    try testing.expectEqual(@as(usize, 0), unequal_telemetry.pair_m4_dispatches);
    try testing.expectEqual(@as(usize, 0), unequal_telemetry.lm_head_m4_dispatches);
    try testing.expectEqual(@as(usize, 0), unequal_telemetry.fallbacks);

    // A Pair image with any co-resident legacy gate/up stream is unsupported,
    // even when its Pair artifact remains valid. Borrow the existing weights in
    // a stack-owned layer table so the loaded model itself is never mutated.
    var co_resident_layers: [NUM_LAYERS]engine.forward.LayerWeights = undefined;
    @memcpy(co_resident_layers[0..], pair_mapped.layers);
    co_resident_layers[0].w_gate_int4 = pair_mapped.layers[0].wq_int4;
    var co_resident_model = pair_mapped;
    co_resident_model.layers = co_resident_layers[0..];
    var co_resident_telemetry: engine.decode_lane4.Telemetry = .{
        .admitted_cohorts = 99,
        .fallbacks = 99,
    };
    var co_resident_allocator = std.testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    try testing.expectError(
        engine.generate.GenerateError.DecodeLane4Unavailable,
        engine.decode_lane4.generate(
            co_resident_allocator.allocator(),
            co_resident_model,
            stochastic_requests,
            .{
                .num_threads = 4,
                .telemetry = &co_resident_telemetry,
            },
        ),
    );
    try testing.expectEqual(@as(usize, 0), co_resident_allocator.allocations);
    try testing.expect(!co_resident_allocator.has_induced_failure);
    try testing.expectEqual(@as(usize, 0), co_resident_telemetry.admitted_cohorts);
    try testing.expectEqual(@as(usize, 0), co_resident_telemetry.layer_m4_graphs);
    try testing.expectEqual(@as(usize, 0), co_resident_telemetry.projection_m4_dispatches);
    try testing.expectEqual(@as(usize, 0), co_resident_telemetry.pair_m4_dispatches);
    try testing.expectEqual(@as(usize, 0), co_resident_telemetry.lm_head_m4_dispatches);
    try testing.expectEqual(@as(usize, 0), co_resident_telemetry.fallbacks);

    // Rows4 projection scales alone are insufficient for token lookup: the
    // packed embedding row decoder requires its canonical FP32 scale stream.
    // Reject that malformed immutable view before ResourceBank reservation or
    // the first request allocation.
    var missing_embedding_scales = pair_mapped.token_embedding_int4.?;
    missing_embedding_scales.scales = &.{};
    var missing_embedding_model = pair_mapped;
    missing_embedding_model.token_embedding_int4 = missing_embedding_scales;
    var missing_scale_slots = [_]engine.resource_bank.Slot{.{}} ** 1;
    var missing_scale_bank = try engine.resource_bank.Bank.init(
        &missing_scale_slots,
        .{},
        0x4c34_5445_5354_0005,
    );
    var missing_scale_resources: engine.generate.RequestResourceTelemetry = .{};
    var missing_scale_allocator = std.testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    try testing.expectError(
        engine.generate.GenerateError.DecodeLane4Unavailable,
        engine.decode_lane4.generate(
            missing_scale_allocator.allocator(),
            missing_embedding_model,
            stochastic_requests,
            .{
                .num_threads = 4,
                .request_resource_bank = &missing_scale_bank,
                .resource_telemetry = &missing_scale_resources,
            },
        ),
    );
    try testing.expectEqual(@as(usize, 0), missing_scale_allocator.allocations);
    try testing.expect(!missing_scale_allocator.has_induced_failure);
    try testing.expectEqual(@as(u64, 0), missing_scale_resources.reservations);
    try testing.expectEqual(@as(u64, 0), missing_scale_resources.commits);
    try testing.expectEqual(@as(u64, 0), missing_scale_resources.releases);
    try testing.expect((try missing_scale_bank.snapshot()).used.isZero());

    // Exercise the second admitted production quantization geometry through
    // the complete source -> Glacier -> PairNibble GLRT -> shared M4 cohort
    // path. The group-8 fixture above cannot stand in for group 16 because its
    // activation scale grid and packed kernel traversal are different.
    _ = try engine.converter.convertSafetensors(
        testing.allocator,
        st_path,
        g16_glacier_path,
        .{
            .quantize_int4 = true,
            .quant_group_size = 16,
            .page_size_bytes = 128,
        },
    );
    var g16_reader = try engine.model.FileReader.open(
        testing.allocator,
        g16_glacier_path,
    );
    defer g16_reader.close();
    var g16_materialized = try engine.loader.loadWithOptions(
        testing.allocator,
        &g16_reader,
        .{},
        .{
            .compact_int4 = true,
            .fp16_scale_cache = true,
        },
    );
    defer g16_materialized.deinit();
    try engine.loader.writePreparedWithOptions(
        testing.allocator,
        &g16_materialized,
        g16_pair_prepared_path,
        g16_materialized.source_fingerprint,
        .{ .mlp_layout = .pair_nibble_required },
    );
    var g16_pair_mapped = try engine.loader.loadPreparedWithOptions(
        testing.allocator,
        g16_pair_prepared_path,
        .{
            .expected_source_fingerprint = g16_materialized.source_fingerprint,
            .mlp_layout = .pair_nibble_required,
        },
    );
    defer g16_pair_mapped.deinit();
    try testing.expectEqual(
        engine.loader.PreparedMlpLayout.pair_nibble,
        g16_pair_mapped.prepared_mlp_layout.?,
    );
    try testing.expectEqual(
        @as(u32, 16),
        g16_pair_mapped.token_embedding_int4.?.group_size,
    );
    try testing.expectEqual(
        @as(u32, 16),
        g16_pair_mapped.lm_head_int4.?.group_size,
    );
    for (g16_pair_mapped.layers) |layer| {
        try testing.expectEqual(
            @as(u32, 16),
            layer.w_gate_up_pair_int4.?.group_size,
        );
        try testing.expectEqual(@as(u32, 16), layer.w_down_int4.?.group_size);
    }

    const g16_requests = [engine.decode_lane4.width]engine.decode_lane4.Request{
        .{
            .prompt = &lane_prompts[0],
            .max_new_tokens = 2,
            .seed = 0x9119,
        },
        .{
            .prompt = &lane_prompts[1],
            .max_new_tokens = 2,
            .seed = 0xa22a,
        },
        .{
            .prompt = &lane_prompts[2],
            .max_new_tokens = 2,
            .seed = 0xb33b,
        },
        .{
            .prompt = &lane_prompts[3],
            .max_new_tokens = 2,
            .seed = 0xc44c,
        },
    };
    var g16_m1_states =
        [_]engine.generate.GenerationStateTelemetry{.{}} ** engine.decode_lane4.width;
    var g16_m1_tokens: [engine.decode_lane4.width][]u32 = undefined;
    var g16_m1_initialized: usize = 0;
    defer for (g16_m1_tokens[0..g16_m1_initialized]) |tokens|
        testing.allocator.free(tokens);
    for (g16_requests, &g16_m1_states, &g16_m1_tokens) |request, *state, *tokens| {
        tokens.* = try generatePairM1Oracle(g16_pair_mapped, request, state);
        g16_m1_initialized += 1;
    }
    var g16_telemetry: engine.decode_lane4.Telemetry = .{};
    var g16_result = try engine.decode_lane4.generate(
        testing.allocator,
        g16_pair_mapped,
        g16_requests,
        .{
            .num_threads = 4,
            .request_resource_bank = &cohort_bank,
            .telemetry = &g16_telemetry,
        },
    );
    defer g16_result.deinit();
    for (0..engine.decode_lane4.width) |lane| {
        try testing.expectEqualSlices(
            u32,
            g16_m1_tokens[lane],
            g16_result.tokens(lane),
        );
        try testing.expectEqualDeep(
            g16_m1_states[lane],
            g16_telemetry.lane_states[lane],
        );
        try testing.expect(g16_m1_states[lane].complete);
        try testing.expectEqual(@as(usize, 2), g16_m1_states[lane].published_tokens);
        try testing.expectEqual(@as(usize, 2), g16_m1_states[lane].sampling_calls);
        try testing.expectEqual(
            lane_prompts[lane].len + 1,
            g16_m1_states[lane].kv_positions,
        );
    }
    try testing.expectEqual(@as(usize, 1), g16_telemetry.admitted_cohorts);
    try testing.expectEqual(@as(usize, 4), g16_telemetry.thread_participants);
    try testing.expectEqual(@as(usize, 4), g16_telemetry.token_graphs);
    try testing.expectEqual(@as(usize, 16), g16_telemetry.layer_m4_graphs);
    try testing.expectEqual(@as(usize, 80), g16_telemetry.projection_m4_dispatches);
    try testing.expectEqual(@as(usize, 48), g16_telemetry.qkv_projection_dispatches);
    try testing.expectEqual(@as(usize, 16), g16_telemetry.qkv_activation_quantizations);
    try testing.expectEqual(@as(usize, 32), g16_telemetry.qkv_quantization_reuses);
    try testing.expectEqual(
        @as(usize, 34),
        g16_telemetry.weight_stationary_norm_dispatches,
    );
    try testing.expectEqual(
        @as(usize, 16),
        g16_telemetry.lane_parallel_attention_dispatches,
    );
    try testing.expectEqual(
        @as(usize, 64),
        g16_telemetry.lane_parallel_attention_tasks,
    );
    try testing.expectEqual(@as(usize, 16), g16_telemetry.pair_m4_dispatches);
    try testing.expectEqual(@as(usize, 2), g16_telemetry.lm_head_m4_dispatches);
    try testing.expectEqual(@as(usize, 16), g16_telemetry.active_lane_steps);
    try testing.expectEqual(@as(usize, 0), g16_telemetry.padded_lane_steps);
    try testing.expectEqual(@as(usize, 0), g16_telemetry.fallbacks);

    var pair_default_reject: engine.generate.PairNibbleExecutionTelemetry = .{};
    var no_alloc_pair = std.testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    try testing.expectError(
        engine.generate.GenerateError.MlpRepresentationUnavailable,
        engine.generate.generate(no_alloc_pair.allocator(), pair_mapped, &prompt, .{
            .max_new_tokens = 4,
            .pair_nibble_telemetry = &pair_default_reject,
        }),
    );
    try testing.expectEqual(@as(usize, 0), no_alloc_pair.allocations);
    try testing.expect(!no_alloc_pair.has_induced_failure);
    try testing.expectEqual(@as(usize, 1), pair_default_reject.rejects);
    try testing.expectEqual(@as(usize, 0), pair_default_reject.fallbacks);

    var separate_pair_reject: engine.generate.PairNibbleExecutionTelemetry = .{};
    var no_alloc_separate = std.testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    try testing.expectError(
        engine.generate.GenerateError.MlpRepresentationUnavailable,
        engine.generate.generate(no_alloc_separate.allocator(), mapped, &prompt, .{
            .max_new_tokens = 4,
            .mlp_representation = .pair_nibble_required,
            .pair_nibble_telemetry = &separate_pair_reject,
        }),
    );
    try testing.expectEqual(@as(usize, 0), no_alloc_separate.allocations);
    try testing.expect(!no_alloc_separate.has_induced_failure);
    try testing.expectEqual(@as(usize, 1), separate_pair_reject.rejects);
    try testing.expectEqual(@as(usize, 0), separate_pair_reject.fallbacks);

    var compact_separate_reject: engine.generate.PairNibbleExecutionTelemetry = .{};
    var no_alloc_compact_separate = std.testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    try testing.expectError(
        engine.generate.GenerateError.MlpRepresentationUnavailable,
        engine.generate.generate(
            no_alloc_compact_separate.allocator(),
            mapped,
            &prompt,
            .{
                .max_new_tokens = 4,
                .decode_frame_mode = .compact_pair_required,
                .pair_nibble_telemetry = &compact_separate_reject,
            },
        ),
    );
    try testing.expectEqual(@as(usize, 0), no_alloc_compact_separate.allocations);
    try testing.expect(!no_alloc_compact_separate.has_induced_failure);
    try testing.expectEqual(@as(usize, 1), compact_separate_reject.rejects);

    const saved_pair_gate = pair_mapped.layers[0].w_gate_int4;
    pair_mapped.layers[0].w_gate_int4 = mapped.layers[0].w_gate_int4;
    defer pair_mapped.layers[0].w_gate_int4 = saved_pair_gate;
    var co_resident_reject: engine.generate.PairNibbleExecutionTelemetry = .{};
    var no_alloc_co_resident = std.testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    try testing.expectError(
        engine.generate.GenerateError.MlpRepresentationUnavailable,
        engine.generate.generate(no_alloc_co_resident.allocator(), pair_mapped, &prompt, .{
            .max_new_tokens = 4,
            .mlp_representation = .pair_nibble_required,
            .pair_nibble_telemetry = &co_resident_reject,
        }),
    );
    try testing.expectEqual(@as(usize, 0), no_alloc_co_resident.allocations);
    try testing.expect(!no_alloc_co_resident.has_induced_failure);
    try testing.expectEqual(@as(usize, 1), co_resident_reject.rejects);
    try testing.expectEqual(@as(usize, 0), co_resident_reject.fallbacks);
    pair_mapped.layers[0].w_gate_int4 = saved_pair_gate;

    // Pair-required M1 consumes only the compact down stream. A future or
    // in-memory image carrying a co-resident expansion must reject before any
    // request allocation, rather than failing at its first worker epoch.
    {
        const saved_down = pair_mapped.layers[0].w_down_int4;
        defer pair_mapped.layers[0].w_down_int4 = saved_down;
        var expanded_down = saved_down.?;
        const expanded_storage = try testing.allocator.alloc(
            i8,
            expanded_down.num_elements,
        );
        defer testing.allocator.free(expanded_storage);
        expanded_down.expanded_i8 = expanded_storage;
        pair_mapped.layers[0].w_down_int4 = expanded_down;

        var expanded_down_reject: engine.generate.PairNibbleExecutionTelemetry = .{};
        var no_alloc_expanded_down = std.testing.FailingAllocator.init(
            testing.allocator,
            .{ .fail_index = 0 },
        );
        try testing.expectError(
            engine.generate.GenerateError.MlpRepresentationUnavailable,
            engine.generate.generate(
                no_alloc_expanded_down.allocator(),
                pair_mapped,
                &prompt,
                .{
                    .max_new_tokens = 4,
                    .mlp_representation = .pair_nibble_required,
                    .pair_nibble_telemetry = &expanded_down_reject,
                },
            ),
        );
        try testing.expectEqual(@as(usize, 0), no_alloc_expanded_down.allocations);
        try testing.expect(!no_alloc_expanded_down.has_induced_failure);
        try testing.expectEqual(@as(usize, 1), expanded_down_reject.rejects);
        try testing.expectEqual(@as(usize, 0), expanded_down_reject.fallbacks);
    }

    var incompatible_reject: engine.generate.PairNibbleExecutionTelemetry = .{};
    var no_alloc_incompatible = std.testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    try testing.expectError(
        engine.generate.GenerateError.MlpRepresentationUnavailable,
        engine.generate.generate(no_alloc_incompatible.allocator(), pair_mapped, &prompt, .{
            .max_new_tokens = 4,
            .int4_activation = .f32,
            .mlp_representation = .pair_nibble_required,
            .pair_nibble_telemetry = &incompatible_reject,
        }),
    );
    try testing.expectEqual(@as(usize, 0), no_alloc_incompatible.allocations);
    try testing.expect(!no_alloc_incompatible.has_induced_failure);
    try testing.expectEqual(@as(usize, 1), incompatible_reject.rejects);
    try testing.expectEqual(@as(usize, 0), incompatible_reject.fallbacks);

    const batch_prompt = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    var separate_prefill_path: engine.generate.PrefillPath = .serial;
    const separate_batch_tokens = try engine.generate.generate(
        testing.allocator,
        mapped,
        &batch_prompt,
        .{
            .max_new_tokens = 4,
            .num_threads = 2,
            .require_batch_prefill = true,
            .prefill_path_out = &separate_prefill_path,
        },
    );
    defer testing.allocator.free(separate_batch_tokens);
    var pair_prefill_path: engine.generate.PrefillPath = .serial;
    var pair_batch_telemetry: engine.generate.PairNibbleExecutionTelemetry = .{};
    var pair_batch_scratch: engine.generate.PairScratchExecutionTelemetry = .{};
    const pair_batch_tokens = try engine.generate.generate(
        testing.allocator,
        pair_mapped,
        &batch_prompt,
        .{
            .max_new_tokens = 4,
            .num_threads = 2,
            .mlp_representation = .pair_nibble_required,
            .pair_nibble_telemetry = &pair_batch_telemetry,
            .pair_scratch_telemetry = &pair_batch_scratch,
            .require_batch_prefill = true,
            .prefill_path_out = &pair_prefill_path,
        },
    );
    defer testing.allocator.free(pair_batch_tokens);
    try testing.expectEqual(engine.generate.PrefillPath.batch, separate_prefill_path);
    try testing.expectEqual(engine.generate.PrefillPath.batch, pair_prefill_path);
    try testing.expectEqualSlices(u32, separate_batch_tokens, pair_batch_tokens);
    try testing.expectEqual(@as(usize, 0), pair_batch_telemetry.prefill_m1_dispatches);
    try testing.expectEqual(@as(usize, 2 * NUM_LAYERS), pair_batch_telemetry.prefill_m4_groups);
    try testing.expectEqual(NUM_LAYERS, pair_batch_telemetry.prefill_tail_dispatches);
    try testing.expectEqual(NUM_LAYERS, pair_batch_telemetry.prefill_tail_rows);
    try testing.expectEqual(@as(usize, 3 * NUM_LAYERS), pair_batch_telemetry.decode_m1_dispatches);
    try testing.expectEqual(
        pair_batch_telemetry.decode_m1_dispatches,
        pair_batch_telemetry.outputless_m1_dispatches,
    );
    try testing.expectEqual(
        @as(usize, (batch_prompt.len + 3) * NUM_LAYERS),
        pair_batch_telemetry.activation_rows_quantized,
    );
    try testing.expectEqual(
        pair_batch_telemetry.activation_rows_quantized,
        pair_batch_telemetry.selected_layer_rows,
    );
    try testing.expectEqual(@as(usize, 0), pair_batch_telemetry.fallbacks);
    try testing.expectEqual(@as(usize, 0), pair_batch_telemetry.rejects);
    try testing.expectEqual(
        engine.int4_executor.PairScratchPolicy.fixed_256,
        pair_batch_scratch.selected_policy,
    );
    try testing.expectEqual(@as(usize, 2), pair_batch_scratch.participants);
    try testing.expectEqual(NUM_LAYERS, pair_batch_scratch.producer_g8_layers);
    try testing.expectEqual(@as(usize, 0), pair_batch_scratch.producer_g16_layers);
    try testing.expectEqual(@as(usize, 32), pair_batch_scratch.selected_g8_rows);
    try testing.expectEqual(@as(usize, 0), pair_batch_scratch.selected_g16_rows);
    try testing.expectEqual(@as(usize, 256), pair_batch_scratch.capacity_rows);
    try testing.expectEqual(@as(usize, 256), pair_batch_scratch.branch_stride_rows);
    try testing.expectEqual(@as(usize, 512), pair_batch_scratch.participant_stride_rows);
    try testing.expectEqual(@as(usize, 1024), pair_batch_scratch.f32_elements);
    try testing.expectEqual(@as(usize, 4096), pair_batch_scratch.bytes);
    try testing.expectEqual(@as(usize, 4096), pair_batch_scratch.fixed_counterfactual_bytes);
    try testing.expectEqual(@as(usize, 0), pair_batch_scratch.reclaimed_bytes);
    try testing.expectEqual(@as(usize, 1), pair_batch_scratch.allocations);
    try testing.expectEqual(
        @as(u64, @intCast(pair_batch_telemetry.outputless_m1_dispatches)),
        pair_batch_scratch.fixed_dispatches,
    );
    try testing.expectEqual(@as(u64, 0), pair_batch_scratch.model_shaped_dispatches);
    try testing.expectEqual(@as(usize, 0), pair_batch_scratch.fallbacks);
    try testing.expectEqual(@as(usize, 0), pair_batch_scratch.rejects);

    // Strict compact-frame eligibility is resolved before every request-owned
    // allocation. An undersized prompt or a one-participant request therefore
    // returns the contract error even under an allocator that fails at its
    // first allocation.
    var short_frame_reject: engine.generate.PairPrefillFrameTelemetry = .{};
    var no_alloc_short_frame = std.testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    try testing.expectError(
        engine.generate.GenerateError.BatchPrefillUnavailable,
        engine.generate.generate(
            no_alloc_short_frame.allocator(),
            pair_mapped,
            batch_prompt[0..7],
            .{
                .max_new_tokens = 1,
                .num_threads = 2,
                .mlp_representation = .pair_nibble_required,
                .pair_prefill_frame_mode = .compact_32_required,
                .pair_prefill_frame_telemetry = &short_frame_reject,
            },
        ),
    );
    try testing.expectEqual(@as(usize, 0), no_alloc_short_frame.allocations);
    try testing.expect(!no_alloc_short_frame.has_induced_failure);
    try testing.expectEqual(@as(usize, 1), short_frame_reject.rejects);

    var serial_frame_reject: engine.generate.PairPrefillFrameTelemetry = .{};
    var no_alloc_serial_frame = std.testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    try testing.expectError(
        engine.generate.GenerateError.BatchPrefillUnavailable,
        engine.generate.generate(
            no_alloc_serial_frame.allocator(),
            pair_mapped,
            &batch_prompt,
            .{
                .max_new_tokens = 1,
                .num_threads = 1,
                .mlp_representation = .pair_nibble_required,
                .pair_prefill_frame_mode = .compact_64_required,
                .pair_prefill_frame_telemetry = &serial_frame_reject,
            },
        ),
    );
    try testing.expectEqual(@as(usize, 0), no_alloc_serial_frame.allocations);
    try testing.expect(!no_alloc_serial_frame.has_induced_failure);
    try testing.expectEqual(@as(usize, 1), serial_frame_reject.rejects);

    // Both strict compact policies must preserve the materialized Pair oracle
    // across an M4 body plus an M1 capsule tail. The nine-row fixture also
    // proves that a requested W32/W64 bound is safely reduced to the largest
    // admitted M4 capacity below the active chunk (W8 here).
    const compact_prefill_cases = [_]struct {
        mode: engine.generate.PairPrefillFrameMode,
        selected: engine.generate.PairPrefillFramePolicy,
    }{
        .{ .mode = .compact_32_required, .selected = .compact_32 },
        .{ .mode = .compact_64_required, .selected = .compact_64 },
    };
    for (compact_prefill_cases) |case| {
        var compact_path: engine.generate.PrefillPath = .serial;
        var compact_pair: engine.generate.PairNibbleExecutionTelemetry = .{};
        var compact_frame: engine.generate.PairPrefillFrameTelemetry = .{};
        const compact_tokens = try engine.generate.generate(
            testing.allocator,
            pair_mapped,
            &batch_prompt,
            .{
                .max_new_tokens = 4,
                .num_threads = 2,
                .mlp_representation = .pair_nibble_required,
                .pair_prefill_frame_mode = case.mode,
                .pair_prefill_frame_telemetry = &compact_frame,
                .pair_nibble_telemetry = &compact_pair,
                .require_batch_prefill = true,
                .prefill_path_out = &compact_path,
            },
        );
        defer testing.allocator.free(compact_tokens);
        try testing.expectEqualSlices(u32, pair_batch_tokens, compact_tokens);
        try testing.expectEqual(engine.generate.PrefillPath.batch, compact_path);
        try testing.expectEqual(case.selected, compact_frame.selected_policy);
        try testing.expectEqual(NUM_LAYERS, compact_frame.producer_g8_layers);
        try testing.expectEqual(
            NUM_LAYERS,
            compact_frame.down_g8_layers + compact_frame.down_g16_layers,
        );
        try testing.expectEqual(@as(usize, 9), compact_frame.chunk_capacity);
        try testing.expectEqual(@as(usize, 1), compact_frame.chunk_count);
        try testing.expectEqual(@as(usize, 1), compact_frame.full_chunks);
        try testing.expectEqual(@as(usize, 0), compact_frame.tail_chunks);
        try testing.expectEqual(@as(usize, 9), compact_frame.peak_active_rows);
        try testing.expectEqual(@as(usize, 8), compact_frame.capsule_rows);
        try testing.expectEqual(@as(usize, 64), compact_frame.tile_rows);
        try testing.expectEqual(@as(usize, 2), compact_frame.task_slots);
        try testing.expectEqual(@as(usize, 0), compact_frame.materialized_layer_uses);
        try testing.expectEqual(NUM_LAYERS, compact_frame.compact_layer_uses);
        try testing.expectEqual(@as(usize, 2 * NUM_LAYERS), compact_frame.capsules);
        try testing.expectEqual(@as(usize, 9 * NUM_LAYERS), compact_frame.pair_input_rows);
        try testing.expectEqual(
            compact_frame.pair_input_rows,
            compact_frame.pair_output_rows,
        );
        try testing.expectEqual(
            compact_frame.pair_output_rows,
            compact_frame.prepared_down_rows,
        );
        try testing.expectEqual(compact_frame.capsules, compact_frame.prepared_down_dispatches);
        try testing.expectEqual(@as(usize, 0), compact_frame.gate_bytes);
        try testing.expectEqual(@as(usize, 0), compact_frame.up_bytes);
        try testing.expectEqual(@as(usize, 0), compact_frame.silu_bytes);
        try testing.expect(compact_frame.tensor_payload_bytes <
            compact_frame.materialized_counterfactual_bytes);
        try testing.expectEqual(
            compact_frame.materialized_counterfactual_bytes -
                compact_frame.tensor_payload_bytes,
            compact_frame.reclaimed_tensor_payload_bytes,
        );
        try testing.expectEqual(@as(usize, 1), compact_frame.arena_sets);
        try testing.expectEqual(@as(usize, 17), compact_frame.logical_slices);
        try testing.expectEqual(@as(usize, 0), compact_frame.fallbacks);
        try testing.expectEqual(@as(usize, 0), compact_frame.rejects);
        try testing.expectEqual(@as(usize, 0), compact_pair.rejects);
    }

    // Outer 256-row chunk tails and inner W64 capsule tails are independent.
    // Exercise both sides of each boundary against the same-artifact
    // materialized oracle so cache commits and final hidden selection cannot
    // accidentally skip or duplicate a row.
    var tail_prompt: [259]u32 = undefined;
    for (&tail_prompt, 0..) |*token, token_index|
        token.* = @intCast((token_index * 17 + 3) % VOCAB);
    for ([_]usize{ 125, 126, 127, 257, 258, 259 }) |prompt_len| {
        const materialized_tail = try engine.generate.generate(
            testing.allocator,
            pair_mapped,
            tail_prompt[0..prompt_len],
            .{
                .max_new_tokens = 1,
                .num_threads = 2,
                .mlp_representation = .pair_nibble_required,
                .pair_prefill_frame_mode = .materialized_required,
            },
        );
        defer testing.allocator.free(materialized_tail);
        var tail_frame: engine.generate.PairPrefillFrameTelemetry = .{};
        const compact_tail = try engine.generate.generate(
            testing.allocator,
            pair_mapped,
            tail_prompt[0..prompt_len],
            .{
                .max_new_tokens = 1,
                .num_threads = 2,
                .mlp_representation = .pair_nibble_required,
                .pair_prefill_frame_mode = .compact_64_required,
                .pair_prefill_frame_telemetry = &tail_frame,
            },
        );
        defer testing.allocator.free(compact_tail);
        try testing.expectEqualSlices(u32, materialized_tail, compact_tail);
        const chunk_capacity = @min(prompt_len, 256);
        const expected_chunks = (prompt_len + chunk_capacity - 1) /
            chunk_capacity;
        const expected_tail_chunks = @intFromBool(
            prompt_len % chunk_capacity != 0,
        );
        const expected_full_chunks = expected_chunks - expected_tail_chunks;
        const expected_capsules_per_layer = (prompt_len + 63) / 64;
        try testing.expectEqual(expected_chunks, tail_frame.chunk_count);
        try testing.expectEqual(expected_full_chunks, tail_frame.full_chunks);
        try testing.expectEqual(
            expected_tail_chunks,
            tail_frame.tail_chunks,
        );
        try testing.expectEqual(
            expected_capsules_per_layer * NUM_LAYERS,
            tail_frame.capsules,
        );
        try testing.expectEqual(
            prompt_len * NUM_LAYERS,
            tail_frame.prepared_down_rows,
        );
        try testing.expectEqual(@as(usize, 0), tail_frame.fallbacks);
        try testing.expectEqual(@as(usize, 0), tail_frame.rejects);
    }

    var fixed_required_scratch: engine.generate.PairScratchExecutionTelemetry = .{};
    const fixed_required_tokens = try engine.generate.generate(
        testing.allocator,
        pair_mapped,
        &batch_prompt,
        .{
            .max_new_tokens = 4,
            .num_threads = 2,
            .mlp_representation = .pair_nibble_required,
            .pair_scratch_mode = .fixed_256_required,
            .pair_scratch_telemetry = &fixed_required_scratch,
            .require_batch_prefill = true,
        },
    );
    defer testing.allocator.free(fixed_required_tokens);
    var shaped_required_scratch: engine.generate.PairScratchExecutionTelemetry = .{};
    const shaped_required_tokens = try engine.generate.generate(
        testing.allocator,
        pair_mapped,
        &batch_prompt,
        .{
            .max_new_tokens = 4,
            .num_threads = 2,
            .mlp_representation = .pair_nibble_required,
            .pair_scratch_mode = .model_shaped_required,
            .pair_scratch_telemetry = &shaped_required_scratch,
            .require_batch_prefill = true,
        },
    );
    defer testing.allocator.free(shaped_required_tokens);
    try testing.expectEqualSlices(u32, pair_batch_tokens, fixed_required_tokens);
    try testing.expectEqualSlices(u32, pair_batch_tokens, shaped_required_tokens);
    try testing.expectEqual(
        engine.int4_executor.PairScratchPolicy.fixed_256,
        fixed_required_scratch.selected_policy,
    );
    try testing.expectEqual(@as(usize, 4096), fixed_required_scratch.bytes);
    try testing.expectEqual(@as(usize, 0), fixed_required_scratch.reclaimed_bytes);
    try testing.expect(fixed_required_scratch.fixed_dispatches > 0);
    try testing.expectEqual(@as(u64, 0), fixed_required_scratch.model_shaped_dispatches);
    try testing.expectEqual(
        engine.int4_executor.PairScratchPolicy.model_shaped,
        shaped_required_scratch.selected_policy,
    );
    try testing.expectEqual(@as(usize, 512), shaped_required_scratch.bytes);
    try testing.expectEqual(@as(usize, 3584), shaped_required_scratch.reclaimed_bytes);
    try testing.expectEqual(@as(u64, 0), shaped_required_scratch.fixed_dispatches);
    try testing.expectEqual(
        fixed_required_scratch.fixed_dispatches,
        shaped_required_scratch.model_shaped_dispatches,
    );

    var zero_required_scratch: engine.generate.PairScratchExecutionTelemetry = .{};
    try testing.expectError(
        engine.generate.GenerateError.MlpRepresentationUnavailable,
        engine.generate.generate(
            testing.allocator,
            pair_mapped,
            &batch_prompt,
            .{
                .max_new_tokens = 0,
                .num_threads = 2,
                .mlp_representation = .pair_nibble_required,
                .pair_scratch_mode = .model_shaped_required,
                .pair_scratch_telemetry = &zero_required_scratch,
            },
        ),
    );
    try testing.expectEqual(
        engine.int4_executor.PairScratchPolicy.disabled,
        zero_required_scratch.selected_policy,
    );
    try testing.expectEqual(@as(usize, 0), zero_required_scratch.allocations);
    try testing.expectEqual(@as(usize, 1), zero_required_scratch.rejects);

    var greedy_telemetry: engine.generate.GreedyOutputTelemetry = .{};
    const logitless_tokens = try engine.generate.generate(
        testing.allocator,
        mapped,
        &prompt,
        .{
            .max_new_tokens = 4,
            .num_threads = 1,
            .greedy_output_mode = .logitless_required,
            .greedy_output_telemetry = &greedy_telemetry,
        },
    );
    defer testing.allocator.free(logitless_tokens);
    try testing.expectEqualSlices(u32, actual_tokens, logitless_tokens);
    try testing.expectEqual(@as(usize, 1), greedy_telemetry.materialized_projections);
    try testing.expectEqual(@as(usize, 3), greedy_telemetry.logitless_projections);
    try testing.expectEqual(@as(usize, 3 * VOCAB), greedy_telemetry.producer_rows);
    try testing.expectEqual(@as(usize, 0), greedy_telemetry.tile_output_bytes);
    try testing.expectEqual(@as(usize, 0), greedy_telemetry.argmax_scan_rows);
    try testing.expect(greedy_telemetry.scratch_bytes > 0);
    try testing.expectEqual(
        @as(usize, VOCAB * @sizeOf(f32)),
        greedy_telemetry.materialized_logits_bytes,
    );
    try testing.expectEqual(
        greedy_telemetry.materialized_logits_bytes,
        greedy_telemetry.steady_state_reclaimed_bytes,
    );
    try testing.expectEqual(@as(usize, 0), greedy_telemetry.fallbacks);
    try testing.expectEqual(@as(usize, 0), greedy_telemetry.rejects);

    const head_binding = engine.generate.eligibilityHeadBinding(mapped);
    var posthead_provider_context: TestEligibilityProvider = .{};
    var posthead_eligibility: engine.generate.EligibilityTelemetry = .{};
    var posthead_greedy: engine.generate.GreedyOutputTelemetry = .{};
    const posthead_tokens = try engine.generate.generate(
        testing.allocator,
        mapped,
        &prompt,
        .{
            .max_new_tokens = 4,
            .num_threads = 1,
            .greedy_output_mode = .domain_posthead_required,
            .greedy_output_telemetry = &posthead_greedy,
            .eligible_vocabulary_provider = posthead_provider_context.provider(
                head_binding,
            ),
            .eligibility_telemetry = &posthead_eligibility,
        },
    );
    defer testing.allocator.free(posthead_tokens);

    var prehead_provider_context: TestEligibilityProvider = .{};
    var prehead_eligibility: engine.generate.EligibilityTelemetry = .{};
    var prehead_greedy: engine.generate.GreedyOutputTelemetry = .{};
    const prehead_tokens = try engine.generate.generate(
        testing.allocator,
        mapped,
        &prompt,
        .{
            .max_new_tokens = 4,
            .num_threads = 1,
            .greedy_output_mode = .domain_prehead_required,
            .greedy_output_telemetry = &prehead_greedy,
            .eligible_vocabulary_provider = prehead_provider_context.provider(
                head_binding,
            ),
            .eligibility_telemetry = &prehead_eligibility,
        },
    );
    defer testing.allocator.free(prehead_tokens);

    try testing.expectEqualSlices(u32, posthead_tokens, prehead_tokens);
    for (prehead_tokens, 0..) |token, step_index| {
        const base = (3 + step_index * 17) % VOCAB;
        var found = false;
        for (0..8) |candidate_index| {
            if (token == (base + candidate_index * 13) % VOCAB) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
    try testing.expectEqual(@as(usize, 4), posthead_provider_context.calls);
    try testing.expectEqual(@as(usize, 4), prehead_provider_context.calls);
    try testing.expectEqual(@as(usize, 4), posthead_eligibility.provider_calls);
    try testing.expectEqual(@as(usize, 4), prehead_eligibility.provider_calls);
    try testing.expectEqual(@as(usize, 4), posthead_eligibility.certificates_accepted);
    try testing.expectEqual(@as(usize, 4), prehead_eligibility.certificates_accepted);
    try testing.expectEqual(@as(usize, 4), posthead_eligibility.posthead_projections);
    try testing.expectEqual(@as(usize, 0), posthead_eligibility.prehead_projections);
    try testing.expectEqual(@as(usize, 0), prehead_eligibility.posthead_projections);
    try testing.expectEqual(@as(usize, 4), prehead_eligibility.prehead_projections);
    try testing.expectEqual(@as(usize, 32), posthead_eligibility.eligible_rows);
    try testing.expectEqual(@as(usize, 32), prehead_eligibility.eligible_rows);
    try testing.expectEqual(
        @as(usize, 4 * VOCAB),
        posthead_eligibility.materialized_dot_rows,
    );
    try testing.expectEqual(
        @as(usize, 4 * VOCAB),
        posthead_eligibility.full_logits_rows_written,
    );
    try testing.expectEqual(
        @as(usize, VOCAB * @sizeOf(f32)),
        posthead_eligibility.full_logits_peak_bytes,
    );
    try testing.expectEqual(@as(usize, 0), prehead_eligibility.materialized_dot_rows);
    try testing.expectEqual(@as(usize, 0), prehead_eligibility.full_logits_rows_written);
    try testing.expectEqual(@as(usize, 0), prehead_eligibility.full_logits_peak_bytes);
    try testing.expect(prehead_eligibility.producer_rows >= 32);
    try testing.expect(prehead_eligibility.producer_rows <= 4 * 32);
    try testing.expectEqual(
        @as(usize, 4 * VOCAB),
        prehead_eligibility.producer_rows + prehead_eligibility.skipped_rows,
    );
    try testing.expectEqual(
        prehead_eligibility.producer_rows - prehead_eligibility.eligible_rows,
        prehead_eligibility.overcomputed_rows,
    );
    try testing.expect(prehead_eligibility.producer_runs > 0);
    try testing.expectEqual(@as(usize, 16), posthead_eligibility.staging_mask_bytes);
    try testing.expectEqual(@as(usize, 16), posthead_eligibility.sealed_mask_bytes);
    try testing.expectEqual(@as(usize, 16), prehead_eligibility.staging_mask_bytes);
    try testing.expectEqual(@as(usize, 16), prehead_eligibility.sealed_mask_bytes);
    try testing.expectEqual(@as(usize, 0), posthead_eligibility.executor_candidate_bytes);
    try testing.expect(prehead_eligibility.executor_candidate_bytes > 0);
    try testing.expect(prehead_eligibility.executor_tile_scratch_bytes > 0);
    try testing.expectEqual(@as(usize, 4), posthead_eligibility.published_tokens);
    try testing.expectEqual(@as(usize, 4), prehead_eligibility.published_tokens);
    try testing.expectEqual(@as(usize, 0), posthead_eligibility.fallbacks);
    try testing.expectEqual(@as(usize, 0), prehead_eligibility.fallbacks);
    try testing.expectEqual(@as(usize, 0), posthead_eligibility.rejects);
    try testing.expectEqual(@as(usize, 0), prehead_eligibility.rejects);
    try testing.expectEqualSlices(
        u8,
        &posthead_eligibility.trace_sha256,
        &prehead_eligibility.trace_sha256,
    );
    try testing.expectEqualSlices(
        u8,
        &posthead_eligibility.last_mask_sha256,
        &prehead_eligibility.last_mask_sha256,
    );

    var concurrent_a: ConcurrentEligibilityRun = .{
        .model = &mapped,
        .prompt = &prompt,
        .head_binding = head_binding,
    };
    var concurrent_b: ConcurrentEligibilityRun = .{
        .model = &mapped,
        .prompt = &prompt,
        .head_binding = head_binding,
    };
    const thread_a = try std.Thread.spawn(.{}, ConcurrentEligibilityRun.run, .{
        &concurrent_a,
    });
    const thread_b = std.Thread.spawn(.{}, ConcurrentEligibilityRun.run, .{
        &concurrent_b,
    }) catch |err| {
        thread_a.join();
        return err;
    };
    thread_a.join();
    thread_b.join();
    defer if (concurrent_a.tokens) |tokens| std.heap.c_allocator.free(tokens);
    defer if (concurrent_b.tokens) |tokens| std.heap.c_allocator.free(tokens);
    try testing.expectEqual(@as(?engine.generate.GenerateError, null), concurrent_a.generate_error);
    try testing.expectEqual(@as(?engine.generate.GenerateError, null), concurrent_b.generate_error);
    try testing.expect(concurrent_a.tokens != null);
    try testing.expect(concurrent_b.tokens != null);
    try testing.expectEqualSlices(u32, concurrent_a.tokens.?, concurrent_b.tokens.?);
    try testing.expect(
        concurrent_a.telemetry.request_nonce !=
            concurrent_b.telemetry.request_nonce,
    );
    try testing.expectEqualSlices(
        u8,
        &concurrent_a.telemetry.trace_sha256,
        &concurrent_b.telemetry.trace_sha256,
    );
    try testing.expectEqual(@as(usize, 2), concurrent_a.provider_context.calls);
    try testing.expectEqual(@as(usize, 2), concurrent_b.provider_context.calls);
    try testing.expectEqual(@as(usize, 4), posthead_greedy.materialized_projections);
    try testing.expectEqual(@as(usize, 0), posthead_greedy.logitless_projections);
    try testing.expectEqual(@as(usize, 0), prehead_greedy.materialized_projections);
    try testing.expectEqual(@as(usize, 4), prehead_greedy.logitless_projections);
    try testing.expectEqual(
        prehead_eligibility.producer_rows,
        prehead_greedy.producer_rows,
    );
    try testing.expectEqual(@as(usize, 0), prehead_greedy.materialized_logits_bytes);

    var eos_context: TestEligibilityProvider = .{};
    var eos_telemetry: engine.generate.EligibilityTelemetry = .{};
    const eos_tokens = try engine.generate.generate(
        testing.allocator,
        mapped,
        &prompt,
        .{
            .max_new_tokens = 4,
            .eos_token = prehead_tokens[0],
            .num_threads = 1,
            .greedy_output_mode = .domain_prehead_required,
            .eligible_vocabulary_provider = eos_context.provider(head_binding),
            .eligibility_telemetry = &eos_telemetry,
        },
    );
    defer testing.allocator.free(eos_tokens);
    try testing.expectEqual(@as(usize, 1), eos_tokens.len);
    try testing.expectEqual(prehead_tokens[0], eos_tokens[0]);
    try testing.expectEqual(@as(usize, 1), eos_context.calls);
    try testing.expectEqual(@as(usize, 1), eos_telemetry.provider_calls);
    try testing.expectEqual(@as(usize, 1), eos_telemetry.certificates_accepted);
    try testing.expectEqual(@as(usize, 1), eos_telemetry.prehead_projections);
    try testing.expectEqual(@as(usize, 1), eos_telemetry.published_tokens);

    var corrupt_context: TestEligibilityProvider = .{ .corrupt_digest = true };
    var corrupt_telemetry: engine.generate.EligibilityTelemetry = .{};
    try testing.expectError(
        engine.generate.GenerateError.EligibilityCertificateRejected,
        engine.generate.generate(testing.allocator, mapped, &prompt, .{
            .max_new_tokens = 2,
            .num_threads = 1,
            .greedy_output_mode = .domain_prehead_required,
            .eligible_vocabulary_provider = corrupt_context.provider(head_binding),
            .eligibility_telemetry = &corrupt_telemetry,
        }),
    );
    try testing.expectEqual(@as(usize, 1), corrupt_context.calls);
    try testing.expectEqual(@as(usize, 1), corrupt_telemetry.provider_calls);
    try testing.expectEqual(@as(usize, 0), corrupt_telemetry.certificates_accepted);
    try testing.expectEqual(@as(usize, 0), corrupt_telemetry.published_tokens);
    try testing.expectEqual(@as(usize, 1), corrupt_telemetry.rejects);

    var stale_prefix_context: TestEligibilityProvider = .{
        .corrupt_prefix = true,
    };
    var stale_prefix_telemetry: engine.generate.EligibilityTelemetry = .{};
    try testing.expectError(
        engine.generate.GenerateError.EligibilityCertificateRejected,
        engine.generate.generate(testing.allocator, mapped, &prompt, .{
            .max_new_tokens = 2,
            .num_threads = 1,
            .greedy_output_mode = .domain_prehead_required,
            .eligible_vocabulary_provider = stale_prefix_context.provider(
                head_binding,
            ),
            .eligibility_telemetry = &stale_prefix_telemetry,
        }),
    );
    try testing.expectEqual(@as(usize, 1), stale_prefix_context.calls);
    try testing.expectEqual(@as(usize, 0), stale_prefix_telemetry.published_tokens);
    try testing.expectEqual(@as(usize, 1), stale_prefix_telemetry.rejects);

    var middle_failure_context: TestEligibilityProvider = .{ .fail_step = 1 };
    var middle_failure_telemetry: engine.generate.EligibilityTelemetry = .{};
    try testing.expectError(
        engine.generate.GenerateError.EligibilityCertificateRejected,
        engine.generate.generate(testing.allocator, mapped, &prompt, .{
            .max_new_tokens = 3,
            .num_threads = 1,
            .greedy_output_mode = .domain_prehead_required,
            .eligible_vocabulary_provider = middle_failure_context.provider(
                head_binding,
            ),
            .eligibility_telemetry = &middle_failure_telemetry,
        }),
    );
    try testing.expectEqual(@as(usize, 2), middle_failure_context.calls);
    try testing.expectEqual(@as(usize, 2), middle_failure_telemetry.provider_calls);
    try testing.expectEqual(@as(usize, 1), middle_failure_telemetry.certificates_accepted);
    try testing.expectEqual(@as(usize, 1), middle_failure_telemetry.published_tokens);
    try testing.expectEqual(@as(usize, 1), middle_failure_telemetry.rejects);

    var wrong_binding_context: TestEligibilityProvider = .{};
    var wrong_binding_telemetry: engine.generate.EligibilityTelemetry = .{};
    var wrong_binding_provider = wrong_binding_context.provider(head_binding);
    wrong_binding_provider.head_binding[0] ^= 0xff;
    try testing.expectError(
        engine.generate.GenerateError.EligibilityCertificateRejected,
        engine.generate.generate(testing.allocator, mapped, &prompt, .{
            .max_new_tokens = 2,
            .num_threads = 1,
            .greedy_output_mode = .domain_prehead_required,
            .eligible_vocabulary_provider = wrong_binding_provider,
            .eligibility_telemetry = &wrong_binding_telemetry,
        }),
    );
    try testing.expectEqual(@as(usize, 0), wrong_binding_context.calls);
    try testing.expectEqual(@as(usize, 1), wrong_binding_telemetry.rejects);

    var empty_context: TestEligibilityProvider = .{ .empty_mask = true };
    var empty_telemetry: engine.generate.EligibilityTelemetry = .{};
    try testing.expectError(
        engine.generate.GenerateError.EligibilityCertificateRejected,
        engine.generate.generate(testing.allocator, mapped, &prompt, .{
            .max_new_tokens = 2,
            .num_threads = 1,
            .greedy_output_mode = .domain_posthead_required,
            .eligible_vocabulary_provider = empty_context.provider(head_binding),
            .eligibility_telemetry = &empty_telemetry,
        }),
    );
    try testing.expectEqual(@as(usize, 1), empty_context.calls);
    try testing.expectEqual(@as(usize, 1), empty_telemetry.rejects);

    var zero_context: TestEligibilityProvider = .{};
    var zero_state: engine.generate.GenerationStateTelemetry = .{};
    const no_tokens = try engine.generate.generate(
        testing.allocator,
        mapped,
        &prompt,
        .{
            .max_new_tokens = 0,
            .num_threads = 1,
            .greedy_output_mode = .domain_prehead_required,
            .eligible_vocabulary_provider = zero_context.provider(head_binding),
            .generation_state_telemetry = &zero_state,
        },
    );
    defer testing.allocator.free(no_tokens);
    try testing.expectEqual(@as(usize, 0), no_tokens.len);
    try testing.expectEqual(@as(usize, 0), zero_context.calls);
    try testing.expect(zero_state.complete);
    try testing.expectEqual(@as(usize, 0), zero_state.kv_positions);
    try testing.expectEqual(@as(usize, 0), zero_state.published_tokens);
    try testing.expectEqual(@as(usize, 0), zero_state.sampling_calls);
    try testing.expectEqual(
        engine.generate.emptyLogicalKvSha256(
            mapped.config.num_layers,
            mapped.config.num_kv_heads * mapped.config.head_dim,
        ),
        zero_state.kv_sha256,
    );
    try testing.expect(!std.mem.eql(
        u8,
        &zero_state.kv_sha256,
        &([_]u8{0} ** 32),
    ));
    try testing.expectEqual(
        engine.generate.tokenSequenceSha256(&.{}),
        zero_state.output_sha256,
    );

    var zero_invalid_context: TestEligibilityProvider = .{};
    var zero_invalid_provider = zero_invalid_context.provider(head_binding);
    zero_invalid_provider.abi = 0;
    try testing.expectError(
        engine.generate.GenerateError.EligibilityCertificateRejected,
        engine.generate.generate(testing.allocator, mapped, &prompt, .{
            .max_new_tokens = 0,
            .num_threads = 1,
            .greedy_output_mode = .domain_prehead_required,
            .eligible_vocabulary_provider = zero_invalid_provider,
        }),
    );
    try testing.expectEqual(@as(usize, 0), zero_invalid_context.calls);

    const invalid_prompt = [_]u32{VOCAB};
    try testing.expectError(
        engine.generate.GenerateError.ShapeMismatch,
        engine.generate.generate(testing.allocator, mapped, &invalid_prompt, .{
            .max_new_tokens = 0,
        }),
    );

    var rejected_telemetry: engine.generate.GreedyOutputTelemetry = .{};
    try testing.expectError(
        engine.generate.GenerateError.LogitlessGreedyUnavailable,
        engine.generate.generate(testing.allocator, mapped, &prompt, .{
            .max_new_tokens = 2,
            .num_threads = 1,
            .sampler = .{ .temperature = 1 },
            .greedy_output_mode = .logitless_required,
            .greedy_output_telemetry = &rejected_telemetry,
        }),
    );
    try testing.expectEqual(@as(usize, 1), rejected_telemetry.rejects);
    try testing.expectEqual(@as(usize, 0), rejected_telemetry.fallbacks);
}

test "loader rejects INT4 index geometry that disagrees with payload" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const st_path = try pathInTmp(&tmp, "model.safetensors");
    defer testing.allocator.free(st_path);
    const glacier_path = try pathInTmp(&tmp, "model.glacier");
    defer testing.allocator.free(glacier_path);

    try writeTinyModelSafetensors(st_path);
    _ = try engine.converter.convertSafetensors(
        testing.allocator,
        st_path,
        glacier_path,
        .{
            .quantize_int4 = true,
            .quant_group_size = 8,
            .page_size_bytes = 128,
        },
    );

    // Compact loading sizes buffers from trusted index geometry before the
    // single payload-read pass. A mismatched byte length must fail before a
    // caller-provided scratch slice can be overrun or partially accepted.
    {
        var reader = try engine.model.FileReader.open(testing.allocator, glacier_path);
        defer reader.close();
        var changed = false;
        for (reader.pages) |*page| {
            if (page.tensor_kind == .attn_q and page.precision == .int4) {
                page.data_len += 1;
                changed = true;
                break;
            }
        }
        try testing.expect(changed);
        try testing.expectError(
            engine.loader.LoaderError.BadPayload,
            engine.loader.loadWithOptions(testing.allocator, &reader, .{}, .{
                .compact_int4 = true,
            }),
        );
    }

    // Eager loading likewise derives the output length from row metadata and
    // then verifies the one decoded payload against it.
    {
        var reader = try engine.model.FileReader.open(testing.allocator, glacier_path);
        defer reader.close();
        var changed = false;
        for (reader.pages) |*page| {
            if (page.tensor_kind == .attn_q and page.precision == .int4) {
                page.row_end += 1;
                changed = true;
                break;
            }
        }
        try testing.expect(changed);
        try testing.expectError(
            engine.loader.LoaderError.BadPayload,
            engine.loader.load(testing.allocator, &reader, .{}),
        );
    }
}
