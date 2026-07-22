//! Model loader — turn a .glacier file into runnable LayerWeights.
//!
//! Reads the page index (FileReader) and groups pages by layer + tensor
//! kind, matching the same name classifier the converter used so the
//! round-trip is exact. Eager mode decodes pages into contiguous f32/f16
//! buffers for full forward compatibility. Compact generation instead merges
//! INT4 pages into a packed logical tensor without materializing float copies.
//! The pager remains separate from this CPU materialization policy.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const fmt = @import("model/format.zig");
const runtime_image = @import("model/runtime_image.zig");
const forward = @import("forward.zig");
const int4_weights = @import("int4_weights.zig");

pub const LoaderError = error{
    NoLayers,
    MissingTensor,
    OutOfMemory,
    BadPayload,
    FileError,
    PreparedImage,
    StalePreparedImage,
    PreparedMlpLayoutMismatch,
};

pub const ModelConfig = struct {
    dim: usize,
    hidden_dim: usize,
    num_layers: usize,
    vocab_size: usize,
    rms_eps: f32 = 1e-6,
    /// Number of attention heads. Recovered from dim by assuming head_dim=64
    /// (the standard Llama/Qwen choice) when not specified.
    num_heads: usize = 1,
    /// Per-head dimension = dim / num_heads.
    head_dim: usize = 0,
    /// RoPE base frequency (theta). 10000 is the Llama default.
    rope_theta: f32 = 10000.0,
    /// Number of key/value heads. Equal to num_heads for MHA, smaller for
    /// GQA (Grouped Query Attention, used by Qwen2/Llama3). Each kv head
    /// is shared by num_heads/num_kv_heads query heads.
    num_kv_heads: usize = 0,
    /// When true, lm_head weights are tied to the token embedding (no
    /// separate lm_head.weight tensor in the checkpoint).
    tie_word_embeddings: bool = false,
};

pub const LoadOptions = struct {
    /// Keep quantized matrix weights packed and skip their decoded F32/F16
    /// copies. This mode is intended for cached generation, whose kernels can
    /// consume INT4 directly. Eager loading remains the default for full
    /// forward/perplexity compatibility.
    compact_int4: bool = false,
    /// Persist an INT8 expansion for MLP matrices in compact mode. This uses
    /// ~0.5 byte/weight extra RAM but enables SDOT without nibble unpacking;
    /// it is opt-in because compact INT4 remains the lower-RSS default.
    int8_mlp_cache: bool = false,
    /// Add an FP16 mirror of all packed scale streams. Four-row-compatible
    /// matrices use a [row_tile][k_group][lane] grid for vector scale loads.
    fp16_scale_cache: bool = false,
};

/// Homogeneous MLP storage selected after validating every prepared layer.
/// Runtime consumers may switch on this value without probing individual
/// layers or inventing a per-layer fallback policy.
pub const PreparedMlpLayout = enum {
    separate,
    pair_nibble,
};

/// Persisted artifact policy. PairNibble is explicitly required rather than
/// preferred: incompatible source streams fail the write instead of silently
/// producing a separate gate/up image.
pub const PreparedMlpWritePolicy = enum {
    separate,
    pair_nibble_required,
};

/// Admission policy for mapped artifacts. The default preserves v1/v2
/// separate compatibility while still requiring one homogeneous layout.
pub const PreparedMlpLoadPolicy = enum {
    any_homogeneous,
    separate_required,
    pair_nibble_required,
};

pub const PreparedWriteOptions = struct {
    mlp_layout: PreparedMlpWritePolicy = .separate,
};

pub const PreparedLoadOptions = struct {
    /// Payload CRC verification is enabled by default because a prepared image
    /// is executable model state. Trusted local caches may opt out and retain
    /// header, index, ABI, bounds, and exact tensor-schema validation.
    verify_payload_crc: bool = true,
    /// V2 descriptor+payload SHA-256 verification is independent of the fast
    /// CRC check and remains enabled unless explicitly disabled.
    verify_payload_digest: bool = true,
    expected_source_fingerprint: ?[32]u8 = null,
    /// `pair_nibble_required` is fail-closed: a valid legacy/separate image is
    /// still rejected and is never used as an implicit fallback.
    mlp_layout: PreparedMlpLoadPolicy = .any_homogeneous,
};

pub const LoadedModel = struct {
    allocator: std.mem.Allocator,
    config: ModelConfig,
    /// Stable source identity used to bind request-time execution evidence to
    /// the model that produced it. Prepared images carry the provenance
    /// fingerprint from their header; materialized sources use
    /// `sourceFingerprint` over typed page metadata and payload CRCs.
    source_fingerprint: [32]u8 = [_]u8{0} ** 32,
    /// One LayerWeights per layer. Each weight slice points into
    /// `weights_arena`, which is owned by this struct.
    layers: []forward.LayerWeights,
    /// All decoded weights live in this arena; freeing the model frees
    /// everything in one shot.
    weights_arena: std.heap.ArenaAllocator,
    /// Final norm weight, shape [dim].
    final_norm: []const f32,
    /// lm_head weights decoded to f32, [vocab, dim] row-major.
    lm_head: []const f32,
    /// Packed lm_head used by compact generation. Null in eager/raw mode.
    lm_head_int4: ?int4_weights.Int4WeightData = null,
    /// Token embedding decoded to f32, [vocab, dim] row-major.
    token_embedding: []const f32,
    /// Packed token embedding used by compact generation. Null in eager/raw mode.
    token_embedding_int4: ?int4_weights.Int4WeightData = null,
    /// Set only for prepared images, after model-wide representation
    /// classification succeeds. Source-model loads leave this null.
    prepared_mlp_layout: ?PreparedMlpLayout = null,
    /// A prepared-runtime image is memory mapped and all of its tensor slices
    /// borrow this mapping. Normal `.glacier` loads leave this null.
    prepared_image: ?runtime_image.MappedImage = null,

    pub fn deinit(self: *LoadedModel) void {
        self.allocator.free(self.layers);
        self.weights_arena.deinit();
        if (self.prepared_image) |*image| image.close();
    }
};

/// Compute a stable identity for a `.glacier` source without rereading all
/// tensor payloads. Page CRCs cover the bytes while the typed page metadata
/// and metadata blob cover their interpretation. Physical offsets are omitted
/// deliberately so a byte-for-byte semantic repack retains the same identity.
pub fn sourceFingerprint(reader: *const fmt.FileReader) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-source-fingerprint-v1\x00");
    hashInt(&hash, u16, reader.header.version);
    hashInt(&hash, u64, @intCast(reader.meta_bytes.len));
    hash.update(reader.meta_bytes);
    hashInt(&hash, u64, @intCast(reader.pages.len));
    for (reader.pages) |page| {
        hashInt(&hash, u64, page.page_id);
        hashInt(&hash, u32, page.layer_idx);
        hashInt(&hash, u32, @intFromEnum(page.tensor_kind));
        hashInt(&hash, u64, page.row_start);
        hashInt(&hash, u64, page.row_end);
        hashInt(&hash, u8, @intFromEnum(page.precision));
        hashInt(&hash, u8, page.quant_group);
        hashInt(&hash, u32, page.crc32);
        hashInt(&hash, u64, page.data_len);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

/// Map a native runtime image and build a `LoadedModel` made entirely of
/// borrowed views. No weight concatenation, nibble repack, or scale conversion
/// occurs on this path.
pub fn loadPrepared(
    allocator: std.mem.Allocator,
    path: []const u8,
) LoaderError!LoadedModel {
    return loadPreparedWithOptions(allocator, path, .{});
}

pub fn loadPreparedWithOptions(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: PreparedLoadOptions,
) LoaderError!LoadedModel {
    var image = runtime_image.MappedImage.openWithOptions(path, .{
        .verify_payload_crc = options.verify_payload_crc,
        .verify_payload_digest = options.verify_payload_digest,
        .expected_source_fingerprint = options.expected_source_fingerprint,
        .expected_abi_fingerprint = runtime_image.ABI_FINGERPRINT,
    }) catch |err| return mapPreparedError(err);
    errdefer image.close();

    const snapshot = image.header.config;
    const source_fingerprint = image.header.source_fingerprint;
    const config = validatePreparedConfig(snapshot) catch |err| return err;
    const prepared_mlp_layout = try validatePreparedRecordSet(&image, config);
    try enforcePreparedMlpLoadPolicy(prepared_mlp_layout, options.mlp_layout);
    const layers = allocator.alloc(forward.LayerWeights, config.num_layers) catch
        return LoaderError.OutOfMemory;
    errdefer allocator.free(layers);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const kv_dim = std.math.mul(usize, config.num_kv_heads, config.head_dim) catch
        return LoaderError.BadPayload;

    for (layers, 0..) |*layer, layer_index| {
        const layer_idx: u32 = std.math.cast(u32, layer_index) orelse
            return LoaderError.BadPayload;
        layer.* = .{
            .input_norm = try preparedRaw(&image, layer_idx, .input_norm, config.dim, true),
            .wq = &.{},
            .wk = &.{},
            .wv = &.{},
            .wo = &.{},
            .bq = try preparedRaw(&image, layer_idx, .attn_q_bias, config.dim, false),
            .bk = try preparedRaw(&image, layer_idx, .attn_k_bias, kv_dim, false),
            .bv = try preparedRaw(&image, layer_idx, .attn_v_bias, kv_dim, false),
            .bo = try preparedRaw(&image, layer_idx, .attn_o_bias, config.dim, false),
            .post_attn_norm = try preparedRaw(
                &image,
                layer_idx,
                .post_attn_norm,
                config.dim,
                true,
            ),
            .w_gate = &.{},
            .w_up = &.{},
            .w_down = &.{},
            .wq_int4 = try preparedInt4(
                &image,
                layer_idx,
                .attn_q,
                config.dim,
                config.dim,
                false,
            ),
            .wk_int4 = try preparedInt4(
                &image,
                layer_idx,
                .attn_k,
                kv_dim,
                config.dim,
                false,
            ),
            .wv_int4 = try preparedInt4(
                &image,
                layer_idx,
                .attn_v,
                kv_dim,
                config.dim,
                false,
            ),
            .wo_int4 = try preparedInt4(
                &image,
                layer_idx,
                .attn_o,
                config.dim,
                config.dim,
                false,
            ),
            .w_gate_int4 = if (prepared_mlp_layout == .separate)
                try preparedInt4(
                    &image,
                    layer_idx,
                    .mlp_gate,
                    config.hidden_dim,
                    config.dim,
                    false,
                )
            else
                null,
            .w_up_int4 = if (prepared_mlp_layout == .separate)
                try preparedInt4(
                    &image,
                    layer_idx,
                    .mlp_up,
                    config.hidden_dim,
                    config.dim,
                    false,
                )
            else
                null,
            .w_gate_up_pair_int4 = if (prepared_mlp_layout == .pair_nibble)
                (try inspectPreparedPairNibble(
                    &image,
                    layer_idx,
                    config.hidden_dim,
                    config.dim,
                )) orelse return LoaderError.MissingTensor
            else
                null,
            .w_down_int4 = try preparedInt4(
                &image,
                layer_idx,
                .mlp_down,
                config.dim,
                config.hidden_dim,
                false,
            ),
        };
    }

    const final_norm = try preparedRaw(
        &image,
        runtime_image.GLOBAL_LAYER,
        .final_norm,
        config.dim,
        true,
    );
    const embedding_int4 = try preparedInt4(
        &image,
        runtime_image.GLOBAL_LAYER,
        .embedding,
        config.vocab_size,
        config.dim,
        true,
    );
    const lm_head_int4 = if (config.tie_word_embeddings)
        embedding_int4
    else
        try preparedInt4(
            &image,
            runtime_image.GLOBAL_LAYER,
            .lm_head,
            config.vocab_size,
            config.dim,
            false,
        );

    return .{
        .allocator = allocator,
        .config = config,
        .source_fingerprint = source_fingerprint,
        .layers = layers,
        .weights_arena = arena,
        .final_norm = final_norm,
        .lm_head = &.{},
        .lm_head_int4 = lm_head_int4,
        .token_embedding = &.{},
        .token_embedding_int4 = embedding_int4,
        .prepared_mlp_layout = prepared_mlp_layout,
        .prepared_image = image,
    };
}

/// Persist the exact compact streams already consumed by the runtime. The
/// caller supplies a provenance fingerprint rooted in the full-file source
/// digest; writing never silently replaces it with the cheaper semantic
/// fingerprint helper above.
pub fn writePrepared(
    allocator: std.mem.Allocator,
    model: *const LoadedModel,
    out_path: []const u8,
    source_fingerprint: [32]u8,
) LoaderError!void {
    return writePreparedWithOptions(
        allocator,
        model,
        out_path,
        source_fingerprint,
        .{},
    );
}

pub fn writePreparedWithOptions(
    allocator: std.mem.Allocator,
    model: *const LoadedModel,
    out_path: []const u8,
    source_fingerprint: [32]u8,
    options: PreparedWriteOptions,
) LoaderError!void {
    _ = try writePreparedWithOptionsAndStats(
        allocator,
        model,
        out_path,
        source_fingerprint,
        options,
    );
}

/// Variant used by preparation evidence to prove that generated records reuse
/// one bounded workspace rather than retaining a full-model transformation.
pub fn writePreparedWithOptionsAndStats(
    allocator: std.mem.Allocator,
    model: *const LoadedModel,
    out_path: []const u8,
    source_fingerprint: [32]u8,
    options: PreparedWriteOptions,
) LoaderError!runtime_image.WriteStats {
    const snapshot = configSnapshot(model.config) catch |err| return err;
    if (model.layers.len != model.config.num_layers) return LoaderError.BadPayload;
    const source_mlp_layout = try classifyPreparedMlpWriteSource(model);
    if (options.mlp_layout == .separate and source_mlp_layout != .separate)
        return LoaderError.PreparedMlpLayoutMismatch;

    var max_pair_bytes: usize = 0;
    var max_pair_scales: usize = 0;
    if (options.mlp_layout == .pair_nibble_required and
        source_mlp_layout == .separate)
    {
        // Validate every source layer before opening an atomic temporary. The
        // exact maxima then define the only generated-payload allocation.
        for (model.layers) |layer| {
            const geometry = try preparedPairGeometryFromSeparate(
                layer.w_gate_int4,
                layer.w_up_int4,
                model.config.hidden_dim,
                model.config.dim,
            );
            max_pair_bytes = @max(max_pair_bytes, geometry.paired_bytes);
            max_pair_scales = @max(max_pair_scales, geometry.paired_scales);
        }
    }
    const pair_bytes = allocator.alloc(u8, max_pair_bytes) catch
        return LoaderError.OutOfMemory;
    defer allocator.free(pair_bytes);
    const pair_scales = allocator.alloc(f16, max_pair_scales) catch
        return LoaderError.OutOfMemory;
    defer allocator.free(pair_scales);

    var records: std.ArrayList(runtime_image.WriteRecord) = .{};
    defer records.deinit(allocator);
    var generated_pairs: std.ArrayList(GeneratedPreparedPair) = .{};
    defer generated_pairs.deinit(allocator);
    const kv_dim = std.math.mul(
        usize,
        model.config.num_kv_heads,
        model.config.head_dim,
    ) catch return LoaderError.BadPayload;

    for (model.layers, 0..) |layer, layer_index| {
        const layer_idx: u32 = std.math.cast(u32, layer_index) orelse
            return LoaderError.BadPayload;
        try appendPreparedRaw(
            allocator,
            &records,
            layer_idx,
            .input_norm,
            layer.input_norm,
            model.config.dim,
            true,
        );
        try appendPreparedInt4(allocator, &records, layer_idx, .attn_q, layer.wq_int4, model.config.dim, model.config.dim, false);
        try appendPreparedInt4(allocator, &records, layer_idx, .attn_k, layer.wk_int4, kv_dim, model.config.dim, false);
        try appendPreparedInt4(allocator, &records, layer_idx, .attn_v, layer.wv_int4, kv_dim, model.config.dim, false);
        try appendPreparedInt4(allocator, &records, layer_idx, .attn_o, layer.wo_int4, model.config.dim, model.config.dim, false);
        try appendPreparedRaw(allocator, &records, layer_idx, .attn_q_bias, layer.bq, model.config.dim, false);
        try appendPreparedRaw(allocator, &records, layer_idx, .attn_k_bias, layer.bk, kv_dim, false);
        try appendPreparedRaw(allocator, &records, layer_idx, .attn_v_bias, layer.bv, kv_dim, false);
        try appendPreparedRaw(allocator, &records, layer_idx, .attn_o_bias, layer.bo, model.config.dim, false);
        try appendPreparedRaw(
            allocator,
            &records,
            layer_idx,
            .post_attn_norm,
            layer.post_attn_norm,
            model.config.dim,
            true,
        );
        switch (options.mlp_layout) {
            .separate => {
                try appendPreparedInt4(allocator, &records, layer_idx, .mlp_gate, layer.w_gate_int4, model.config.hidden_dim, model.config.dim, false);
                try appendPreparedInt4(allocator, &records, layer_idx, .mlp_up, layer.w_up_int4, model.config.hidden_dim, model.config.dim, false);
            },
            .pair_nibble_required => switch (source_mlp_layout) {
                .separate => try appendPreparedPairNibbleFromSeparatePlan(
                    allocator,
                    &records,
                    &generated_pairs,
                    layer_idx,
                    layer.w_gate_int4,
                    layer.w_up_int4,
                    model.config.hidden_dim,
                    model.config.dim,
                    pair_bytes,
                    pair_scales,
                ),
                .pair_nibble => try appendPreparedPairNibbleData(
                    allocator,
                    &records,
                    layer_idx,
                    layer.w_gate_up_pair_int4,
                    model.config.hidden_dim,
                    model.config.dim,
                ),
            },
        }
        try appendPreparedInt4(allocator, &records, layer_idx, .mlp_down, layer.w_down_int4, model.config.dim, model.config.hidden_dim, false);
    }

    try appendPreparedRaw(
        allocator,
        &records,
        runtime_image.GLOBAL_LAYER,
        .final_norm,
        model.final_norm,
        model.config.dim,
        true,
    );
    try appendPreparedInt4(
        allocator,
        &records,
        runtime_image.GLOBAL_LAYER,
        .embedding,
        model.token_embedding_int4,
        model.config.vocab_size,
        model.config.dim,
        true,
    );
    if (!model.config.tie_word_embeddings) {
        try appendPreparedInt4(
            allocator,
            &records,
            runtime_image.GLOBAL_LAYER,
            .lm_head,
            model.lm_head_int4,
            model.config.vocab_size,
            model.config.dim,
            false,
        );
    }

    var provider_context: PreparedPairProviderContext = .{
        .sources = generated_pairs.items,
        .pair_bytes = pair_bytes,
        .pair_scales = pair_scales,
    };
    const stats = runtime_image.writeAtomicWithProvider(
        allocator,
        out_path,
        .{
            .config = snapshot,
            .source_fingerprint = source_fingerprint,
        },
        records.items,
        .{
            .context = &provider_context,
            .materialize = PreparedPairProviderContext.materialize,
            .finish = PreparedPairProviderContext.finish,
        },
    ) catch |err| return mapPreparedError(err);
    return stats;
}

fn classifyPreparedMlpWriteSource(
    model: *const LoadedModel,
) LoaderError!PreparedMlpLayout {
    var model_layout: ?PreparedMlpLayout = null;
    for (model.layers) |layer| {
        const has_gate = layer.w_gate_int4 != null;
        const has_up = layer.w_up_int4 != null;
        const has_pair = layer.w_gate_up_pair_int4 != null;
        const layer_layout: PreparedMlpLayout = if (has_pair) pair: {
            if (has_gate or has_up) return LoaderError.BadPayload;
            break :pair .pair_nibble;
        } else separate: {
            if (!has_gate or !has_up) return LoaderError.MissingTensor;
            break :separate .separate;
        };
        if (model_layout) |expected| {
            if (expected != layer_layout) return LoaderError.BadPayload;
        } else {
            model_layout = layer_layout;
        }
    }
    const layout = model_layout orelse return LoaderError.NoLayers;
    if (model.prepared_mlp_layout) |declared| {
        if (declared != layout) return LoaderError.BadPayload;
    }
    return layout;
}

fn hashInt(hash: *std.crypto.hash.sha2.Sha256, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hash.update(&bytes);
}

fn validatePreparedConfig(snapshot: runtime_image.ConfigSnapshot) LoaderError!ModelConfig {
    const dim: usize = snapshot.dim;
    const hidden_dim: usize = snapshot.hidden_dim;
    const num_layers: usize = snapshot.layers;
    const vocab_size: usize = snapshot.vocab;
    const num_heads: usize = snapshot.heads;
    const head_dim: usize = snapshot.head_dim;
    const num_kv_heads: usize = snapshot.kv_heads;
    if (dim == 0 or hidden_dim == 0 or num_layers == 0 or vocab_size == 0 or
        num_heads == 0 or head_dim == 0 or num_kv_heads == 0 or
        !std.math.isFinite(snapshot.rms_eps) or snapshot.rms_eps <= 0 or
        !std.math.isFinite(snapshot.rope_theta) or snapshot.rope_theta <= 0)
    {
        return LoaderError.BadPayload;
    }
    const query_dim = std.math.mul(usize, num_heads, head_dim) catch
        return LoaderError.BadPayload;
    if (query_dim != dim or num_kv_heads > num_heads or
        num_heads % num_kv_heads != 0)
    {
        return LoaderError.BadPayload;
    }
    _ = std.math.mul(usize, num_kv_heads, head_dim) catch
        return LoaderError.BadPayload;
    return .{
        .dim = dim,
        .hidden_dim = hidden_dim,
        .num_layers = num_layers,
        .vocab_size = vocab_size,
        .rms_eps = snapshot.rms_eps,
        .num_heads = num_heads,
        .head_dim = head_dim,
        .rope_theta = snapshot.rope_theta,
        .num_kv_heads = num_kv_heads,
        .tie_word_embeddings = snapshot.tie_embeddings,
    };
}

fn validatePreparedRecordSet(
    image: *const runtime_image.MappedImage,
    config: ModelConfig,
) LoaderError!PreparedMlpLayout {
    for (0..image.recordCount()) |index| {
        const record = image.recordAt(index) catch return LoaderError.PreparedImage;
        if (!isExpectedPreparedRecord(
            config,
            record.key.layer_idx,
            record.key.kind,
            record.role,
        ))
            return LoaderError.BadPayload;
    }

    var model_layout: ?PreparedMlpLayout = null;
    for (0..config.num_layers) |layer_index| {
        const layer_idx = std.math.cast(u32, layer_index) orelse
            return LoaderError.BadPayload;
        const has_gate = image.find(layer_idx, .mlp_gate) != null;
        const has_up = image.find(layer_idx, .mlp_up) != null;
        const has_pair = image.findRole(layer_idx, .mlp_gate_up_pair) != null;
        const layer_layout: PreparedMlpLayout = if (has_pair) pair: {
            if (has_gate or has_up) return LoaderError.BadPayload;
            _ = (try inspectPreparedPairNibble(
                image,
                layer_idx,
                config.hidden_dim,
                config.dim,
            )) orelse return LoaderError.MissingTensor;
            break :pair .pair_nibble;
        } else separate: {
            // One legacy branch without the other is never a usable fallback.
            if (!has_gate or !has_up) return LoaderError.MissingTensor;
            _ = try preparedInt4(
                image,
                layer_idx,
                .mlp_gate,
                config.hidden_dim,
                config.dim,
                false,
            );
            _ = try preparedInt4(
                image,
                layer_idx,
                .mlp_up,
                config.hidden_dim,
                config.dim,
                false,
            );
            break :separate .separate;
        };
        if (model_layout) |expected| {
            if (expected != layer_layout) return LoaderError.BadPayload;
        } else {
            model_layout = layer_layout;
        }
    }
    return model_layout orelse return LoaderError.NoLayers;
}

fn enforcePreparedMlpLoadPolicy(
    layout: PreparedMlpLayout,
    policy: PreparedMlpLoadPolicy,
) LoaderError!void {
    switch (policy) {
        .any_homogeneous => {},
        .separate_required => if (layout != .separate)
            return LoaderError.PreparedMlpLayoutMismatch,
        .pair_nibble_required => if (layout != .pair_nibble)
            return LoaderError.PreparedMlpLayoutMismatch,
    }
}

fn isExpectedPreparedRecord(
    config: ModelConfig,
    layer_idx: u32,
    kind: fmt.TensorKind,
    role: runtime_image.Role,
) bool {
    if (role == .mlp_gate_up_pair) {
        return layer_idx != runtime_image.GLOBAL_LAYER and
            @as(usize, layer_idx) < config.num_layers;
    }
    if (role != .tensor) return false;
    if (layer_idx == runtime_image.GLOBAL_LAYER) {
        return switch (kind) {
            .final_norm, .embedding => true,
            .lm_head => !config.tie_word_embeddings,
            else => false,
        };
    }
    if (@as(usize, layer_idx) >= config.num_layers) return false;
    return switch (kind) {
        .input_norm,
        .attn_q,
        .attn_k,
        .attn_v,
        .attn_o,
        .attn_q_bias,
        .attn_k_bias,
        .attn_v_bias,
        .attn_o_bias,
        .post_attn_norm,
        .mlp_gate,
        .mlp_up,
        .mlp_down,
        => true,
        else => false,
    };
}

fn configSnapshot(config: ModelConfig) LoaderError!runtime_image.ConfigSnapshot {
    const snapshot: runtime_image.ConfigSnapshot = .{
        .dim = std.math.cast(u32, config.dim) orelse return LoaderError.BadPayload,
        .hidden_dim = std.math.cast(u32, config.hidden_dim) orelse return LoaderError.BadPayload,
        .layers = std.math.cast(u32, config.num_layers) orelse return LoaderError.BadPayload,
        .vocab = std.math.cast(u32, config.vocab_size) orelse return LoaderError.BadPayload,
        .heads = std.math.cast(u32, config.num_heads) orelse return LoaderError.BadPayload,
        .head_dim = std.math.cast(u32, config.head_dim) orelse return LoaderError.BadPayload,
        .kv_heads = std.math.cast(u32, config.num_kv_heads) orelse return LoaderError.BadPayload,
        .rms_eps = config.rms_eps,
        .rope_theta = config.rope_theta,
        .tie_embeddings = config.tie_word_embeddings,
    };
    _ = try validatePreparedConfig(snapshot);
    return snapshot;
}

fn preparedRaw(
    image: *const runtime_image.MappedImage,
    layer_idx: u32,
    kind: fmt.TensorKind,
    expected_elements: usize,
    required: bool,
) LoaderError![]const f32 {
    const record = image.find(layer_idx, kind) orelse {
        if (required) return LoaderError.MissingTensor;
        return &.{};
    };
    const expected_u32 = std.math.cast(u32, expected_elements) orelse
        return LoaderError.BadPayload;
    const expected_u64 = std.math.cast(u64, expected_elements) orelse
        return LoaderError.BadPayload;
    if (record.encoding != .raw_f32 or record.packed_layout != .none or
        record.group_size != 0 or record.out_f != 1 or
        record.in_f != expected_u32 or record.num_elements != expected_u64)
    {
        return LoaderError.BadPayload;
    }
    const values = image.f32View(record, .raw) catch return LoaderError.BadPayload;
    if (values.len != expected_elements) return LoaderError.BadPayload;
    return values;
}

fn preparedInt4(
    image: *const runtime_image.MappedImage,
    layer_idx: u32,
    kind: fmt.TensorKind,
    out_f: usize,
    in_f: usize,
    require_f32_scales: bool,
) LoaderError!int4_weights.Int4WeightData {
    const record = image.find(layer_idx, kind) orelse return LoaderError.MissingTensor;
    const out_u32 = std.math.cast(u32, out_f) orelse return LoaderError.BadPayload;
    const in_u32 = std.math.cast(u32, in_f) orelse return LoaderError.BadPayload;
    const num_elements = std.math.mul(usize, out_f, in_f) catch
        return LoaderError.BadPayload;
    const num_u64 = std.math.cast(u64, num_elements) orelse return LoaderError.BadPayload;
    if (record.encoding != .int4 or record.group_size == 0 or
        record.out_f != out_u32 or record.in_f != in_u32 or
        record.num_elements != num_u64)
    {
        return LoaderError.BadPayload;
    }
    const slices = image.int4Slices(record) catch return LoaderError.BadPayload;
    const packed_count = ceilDiv(num_elements, 2);
    const scale_count = ceilDiv(num_elements, @as(usize, record.group_size));
    if (slices.packed_bytes.len != packed_count or
        (slices.scales_f32.len != 0 and slices.scales_f32.len != scale_count) or
        (slices.scales_f16.len != 0 and slices.scales_f16.len != scale_count) or
        (slices.scales_f16_rows4.len != 0 and
            slices.scales_f16_rows4.len != scale_count) or
        (slices.scales_f32.len == 0 and slices.scales_f16.len == 0 and
            slices.scales_f16_rows4.len == 0) or
        (require_f32_scales and slices.scales_f32.len != scale_count))
    {
        return LoaderError.BadPayload;
    }
    const layout: int4_weights.PackedLayout = switch (record.packed_layout) {
        .row_major => .row_major,
        .rows4_k16 => blk: {
            if (out_f % 4 != 0 or in_f % 16 != 0 or
                slices.scales_f16_rows4.len != scale_count)
            {
                return LoaderError.BadPayload;
            }
            break :blk .rows4_k16;
        },
        .none => return LoaderError.BadPayload,
    };
    return .{
        .packed_bytes = slices.packed_bytes,
        .scales = slices.scales_f32,
        .scales_f16 = slices.scales_f16,
        .scales_f16_rows4 = slices.scales_f16_rows4,
        .group_size = record.group_size,
        .num_elements = num_elements,
        .packed_layout = layout,
    };
}

/// Bind a non-duplicated PairNibble record to its typed borrowed view. The
/// returned slices point directly into `image`; callers must keep the mapping
/// alive and must not reconstruct legacy single-projection streams from it.
pub fn inspectPreparedPairNibble(
    image: *const runtime_image.MappedImage,
    layer_idx: u32,
    out_f: usize,
    in_f: usize,
) LoaderError!?int4_weights.PairNibbleWeightData {
    const record = image.findRole(layer_idx, .mlp_gate_up_pair) orelse return null;
    const out_u32 = std.math.cast(u32, out_f) orelse return LoaderError.BadPayload;
    const in_u32 = std.math.cast(u32, in_f) orelse return LoaderError.BadPayload;
    const num_elements = std.math.mul(usize, out_f, in_f) catch
        return LoaderError.BadPayload;
    const num_u64 = std.math.cast(u64, num_elements) orelse
        return LoaderError.BadPayload;
    if (record.encoding != .pair_nibble or record.packed_layout != .none or
        record.pair_nibble_layout != .rows4_k16 or
        record.out_f != out_u32 or record.in_f != in_u32 or
        record.num_elements != num_u64)
    {
        return LoaderError.BadPayload;
    }
    const slices = image.pairNibbleSlices(record) catch
        return LoaderError.BadPayload;
    const layout: int4_weights.PairNibbleLayout =
        .gate_low_up_high_rows4_k16;
    const weights: int4_weights.PairNibbleWeightData = .{
        .paired_bytes = slices.packed_pairs,
        .scales_f16_pairs = slices.scales_f16_rows4,
        .group_size = record.group_size,
        .out_f = out_f,
        .in_f = in_f,
        .num_elements_per_branch = num_elements,
        .geometry_commitment = int4_weights.pairNibbleGeometryCommitment(
            layout,
            out_f,
            in_f,
            record.group_size,
        ) catch return LoaderError.BadPayload,
        .packed_layout = layout,
    };
    int4_weights.validatePairNibble(weights) catch return LoaderError.BadPayload;
    return weights;
}

fn appendPreparedRaw(
    allocator: std.mem.Allocator,
    records: *std.ArrayList(runtime_image.WriteRecord),
    layer_idx: u32,
    kind: fmt.TensorKind,
    values: []const f32,
    expected_elements: usize,
    required: bool,
) LoaderError!void {
    if (values.len == 0 and !required) return;
    if (values.len != expected_elements or expected_elements == 0)
        return if (values.len == 0) LoaderError.MissingTensor else LoaderError.BadPayload;
    const in_f = std.math.cast(u32, expected_elements) orelse
        return LoaderError.BadPayload;
    records.append(allocator, .{
        .key = .{ .layer_idx = layer_idx, .kind = kind },
        .encoding = .raw_f32,
        .packed_layout = .none,
        .group_size = 0,
        .out_f = 1,
        .in_f = in_f,
        .num_elements = expected_elements,
        .raw = std.mem.sliceAsBytes(values),
    }) catch return LoaderError.OutOfMemory;
}

const PreparedPairGeometry = struct {
    paired_bytes: usize,
    paired_scales: usize,
};

const GeneratedPreparedPair = struct {
    record_index: usize,
    gate: int4_weights.Int4WeightData,
    up: int4_weights.Int4WeightData,
    out_f: usize,
    geometry: PreparedPairGeometry,
};

const PreparedPairProviderContext = struct {
    sources: []const GeneratedPreparedPair,
    pair_bytes: []u8,
    pair_scales: []f16,
    next_source: usize = 0,

    fn materialize(
        context: *anyopaque,
        record_index: usize,
        planned: runtime_image.WriteRecord,
    ) anyerror!runtime_image.MaterializedWriteRecord {
        const self: *PreparedPairProviderContext = @ptrCast(@alignCast(context));
        if (self.next_source >= self.sources.len)
            return .{ .record = planned };
        const source = self.sources[self.next_source];
        if (source.record_index > record_index)
            return .{ .record = planned };
        if (source.record_index < record_index)
            return error.GeneratedRecordSkipped;

        const paired = try int4_weights.pairRows4K16(
            source.gate,
            source.up,
            source.out_f,
            self.pair_bytes[0..source.geometry.paired_bytes],
            self.pair_scales[0..source.geometry.paired_scales],
        );
        try int4_weights.validatePairNibble(paired);
        self.next_source += 1;

        var materialized = planned;
        materialized.packed_bytes = paired.paired_bytes;
        materialized.scales_f16_rows4 = std.mem.sliceAsBytes(
            paired.scales_f16_pairs,
        );
        const scale_bytes = std.math.mul(
            u64,
            source.geometry.paired_scales,
            @sizeOf(f16),
        ) catch return error.WorkspaceOverflow;
        const workspace_bytes = std.math.add(
            u64,
            source.geometry.paired_bytes,
            scale_bytes,
        ) catch return error.WorkspaceOverflow;
        return .{
            .record = materialized,
            .generated = true,
            .workspace_bytes = workspace_bytes,
        };
    }

    fn finish(context: *anyopaque) anyerror!void {
        const self: *PreparedPairProviderContext = @ptrCast(@alignCast(context));
        if (self.next_source != self.sources.len)
            return error.GeneratedRecordSkipped;
    }
};

fn preparedPairGeometryFromSeparate(
    maybe_gate: ?int4_weights.Int4WeightData,
    maybe_up: ?int4_weights.Int4WeightData,
    out_f: usize,
    in_f: usize,
) LoaderError!PreparedPairGeometry {
    const gate = maybe_gate orelse return LoaderError.MissingTensor;
    const up = maybe_up orelse return LoaderError.MissingTensor;
    const num_elements = std.math.mul(usize, out_f, in_f) catch
        return LoaderError.BadPayload;
    const packed_count = ceilDiv(num_elements, 2);
    if (out_f == 0 or out_f % 4 != 0 or in_f == 0 or in_f % 16 != 0 or
        gate.packed_layout != .rows4_k16 or
        up.packed_layout != .rows4_k16 or
        gate.num_elements != num_elements or up.num_elements != num_elements or
        (gate.group_size != 8 and gate.group_size != 16) or
        gate.group_size != up.group_size or
        num_elements % gate.group_size != 0 or
        gate.packed_bytes.len != packed_count or
        up.packed_bytes.len != packed_count or
        gate.expanded_i8.len != 0 or up.expanded_i8.len != 0)
    {
        return LoaderError.BadPayload;
    }
    const source_scale_count = num_elements / gate.group_size;
    if (gate.scales_f16_rows4.len != source_scale_count or
        up.scales_f16_rows4.len != source_scale_count)
    {
        return LoaderError.BadPayload;
    }
    return .{
        .paired_bytes = num_elements,
        .paired_scales = std.math.mul(
            usize,
            source_scale_count,
            2,
        ) catch return LoaderError.BadPayload,
    };
}

fn appendPreparedPairNibbleFromSeparatePlan(
    allocator: std.mem.Allocator,
    records: *std.ArrayList(runtime_image.WriteRecord),
    generated_pairs: *std.ArrayList(GeneratedPreparedPair),
    layer_idx: u32,
    maybe_gate: ?int4_weights.Int4WeightData,
    maybe_up: ?int4_weights.Int4WeightData,
    out_f: usize,
    in_f: usize,
    pair_bytes: []u8,
    pair_scales: []f16,
) LoaderError!void {
    const gate = maybe_gate orelse return LoaderError.MissingTensor;
    const up = maybe_up orelse return LoaderError.MissingTensor;
    const geometry = try preparedPairGeometryFromSeparate(
        gate,
        up,
        out_f,
        in_f,
    );
    if (pair_bytes.len < geometry.paired_bytes or
        pair_scales.len < geometry.paired_scales)
    {
        return LoaderError.OutOfMemory;
    }
    const record_index = records.items.len;
    records.append(allocator, .{
        .key = .{ .layer_idx = layer_idx, .kind = .other },
        .role = .mlp_gate_up_pair,
        .encoding = .pair_nibble,
        .packed_layout = .none,
        .pair_nibble_layout = .rows4_k16,
        .group_size = gate.group_size,
        .out_f = std.math.cast(u32, out_f) orelse
            return LoaderError.BadPayload,
        .in_f = std.math.cast(u32, in_f) orelse
            return LoaderError.BadPayload,
        .num_elements = geometry.paired_bytes,
        .packed_bytes = pair_bytes[0..geometry.paired_bytes],
        .scales_f16_rows4 = std.mem.sliceAsBytes(
            pair_scales[0..geometry.paired_scales],
        ),
    }) catch return LoaderError.OutOfMemory;
    generated_pairs.append(allocator, .{
        .record_index = record_index,
        .gate = gate,
        .up = up,
        .out_f = out_f,
        .geometry = geometry,
    }) catch return LoaderError.OutOfMemory;
}

fn appendPreparedPairNibbleData(
    allocator: std.mem.Allocator,
    records: *std.ArrayList(runtime_image.WriteRecord),
    layer_idx: u32,
    maybe_paired: ?int4_weights.PairNibbleWeightData,
    out_f: usize,
    in_f: usize,
) LoaderError!void {
    const paired = maybe_paired orelse return LoaderError.MissingTensor;
    int4_weights.validatePairNibble(paired) catch return LoaderError.BadPayload;
    if (paired.out_f != out_f or paired.in_f != in_f)
        return LoaderError.BadPayload;
    records.append(allocator, .{
        // PairNibble is an execution artifact. Its role is canonical and its
        // source TensorKind is intentionally the neutral `.other` value.
        .key = .{ .layer_idx = layer_idx, .kind = .other },
        .role = .mlp_gate_up_pair,
        .encoding = .pair_nibble,
        .packed_layout = .none,
        .pair_nibble_layout = .rows4_k16,
        .group_size = paired.group_size,
        .out_f = std.math.cast(u32, paired.out_f) orelse
            return LoaderError.BadPayload,
        .in_f = std.math.cast(u32, paired.in_f) orelse
            return LoaderError.BadPayload,
        .num_elements = paired.num_elements_per_branch,
        .packed_bytes = paired.paired_bytes,
        .scales_f16_rows4 = std.mem.sliceAsBytes(paired.scales_f16_pairs),
    }) catch return LoaderError.OutOfMemory;
}

fn appendPreparedInt4(
    allocator: std.mem.Allocator,
    records: *std.ArrayList(runtime_image.WriteRecord),
    layer_idx: u32,
    kind: fmt.TensorKind,
    maybe_weights: ?int4_weights.Int4WeightData,
    out_f: usize,
    in_f: usize,
    require_f32_scales: bool,
) LoaderError!void {
    const weights = maybe_weights orelse return LoaderError.MissingTensor;
    const num_elements = std.math.mul(usize, out_f, in_f) catch
        return LoaderError.BadPayload;
    if (weights.group_size == 0 or weights.num_elements != num_elements or
        weights.packed_bytes.len != ceilDiv(num_elements, 2))
    {
        return LoaderError.BadPayload;
    }
    const scale_count = ceilDiv(num_elements, @as(usize, weights.group_size));
    if ((weights.scales.len != 0 and weights.scales.len != scale_count) or
        (weights.scales_f16.len != 0 and weights.scales_f16.len != scale_count) or
        (weights.scales_f16_rows4.len != 0 and
            weights.scales_f16_rows4.len != scale_count) or
        (weights.scales.len == 0 and weights.scales_f16.len == 0 and
            weights.scales_f16_rows4.len == 0) or
        (require_f32_scales and weights.scales.len != scale_count))
    {
        return LoaderError.BadPayload;
    }
    const layout: runtime_image.PackedLayout = switch (weights.packed_layout) {
        .row_major => .row_major,
        .rows4_k16 => blk: {
            if (out_f % 4 != 0 or in_f % 16 != 0 or
                weights.scales_f16_rows4.len != scale_count)
            {
                return LoaderError.BadPayload;
            }
            break :blk .rows4_k16;
        },
    };
    records.append(allocator, .{
        .key = .{ .layer_idx = layer_idx, .kind = kind },
        .encoding = .int4,
        .packed_layout = layout,
        .group_size = weights.group_size,
        .out_f = std.math.cast(u32, out_f) orelse return LoaderError.BadPayload,
        .in_f = std.math.cast(u32, in_f) orelse return LoaderError.BadPayload,
        .num_elements = num_elements,
        .packed_bytes = weights.packed_bytes,
        .scales_f32 = std.mem.sliceAsBytes(weights.scales),
        .scales_f16 = std.mem.sliceAsBytes(weights.scales_f16),
        .scales_f16_rows4 = std.mem.sliceAsBytes(weights.scales_f16_rows4),
    }) catch return LoaderError.OutOfMemory;
}

fn mapPreparedError(err: anyerror) LoaderError {
    return switch (err) {
        error.OutOfMemory => LoaderError.OutOfMemory,
        error.FileNotFound, error.AccessDenied, error.NotDir, error.IsDir => LoaderError.FileError,
        error.SourceFingerprintMismatch, error.AbiFingerprintMismatch => LoaderError.StalePreparedImage,
        else => LoaderError.PreparedImage,
    };
}

/// Group every page in the file by (layer, tensor_kind), then materialize
/// each group as a contiguous payload.
///
/// `override` (optional): values from a JSON sidecar that take precedence
/// over the page-metadata heuristics. Pass an empty struct to rely purely
/// on heuristics.
pub fn load(
    allocator: std.mem.Allocator,
    reader: *fmt.FileReader,
    override: @import("config.zig").ModelConfigOverride,
) LoaderError!LoadedModel {
    return loadWithOptions(allocator, reader, override, .{});
}

/// Load a model with explicit materialization policy.
pub fn loadWithOptions(
    allocator: std.mem.Allocator,
    reader: *fmt.FileReader,
    override: @import("config.zig").ModelConfigOverride,
    options: LoadOptions,
) LoaderError!LoadedModel {
    if (reader.pages.len == 0) return LoaderError.NoLayers;
    const source_fingerprint = sourceFingerprint(reader);
    const use_fp16_scale_cache = options.fp16_scale_cache and
        builtin.cpu.arch == .aarch64;

    // First pass: discover model geometry from the page metadata.
    // Norm weights are stored raw (un-quantized), so their row_end is the
    // true element count = dim. Other tensors are INT4-quantized so their
    // row_end is the total element count (rows × cols), not a single dim.
    var num_layers: u32 = 0;
    var dim: usize = 0;
    var hidden_dim: usize = 0;
    var vocab_size: usize = 0;
    for (reader.pages) |p| {
        if (p.layer_idx + 1 > num_layers) num_layers = p.layer_idx + 1;
        switch (p.tensor_kind) {
            .input_norm, .post_attn_norm, .final_norm => {
                // Raw FP32 storage: row_end is the true dimension.
                if (p.row_end > dim) dim = p.row_end;
            },
            .mlp_up, .mlp_gate, .mlp_down => {
                // INT4-quantized [hidden, dim] or [dim, hidden]: row_end is
                // hidden × dim. We cannot recover hidden directly without
                // knowing dim first, so derive hidden from the *largest*
                // such tensor once dim is known. Fall back to a guess of
                // 4 × dim if no norm was found.
                if (p.row_end > hidden_dim) hidden_dim = p.row_end;
            },
            .embedding, .lm_head => {
                // [vocab, dim] or [vocab, dim] quantized: row_end = vocab × dim.
                if (p.row_end > vocab_size) vocab_size = p.row_end;
            },
            else => {},
        }
    }
    // If we found a norm, dim is now set. Recover hidden_dim and vocab_size
    // (which were stored as element counts) by dividing by dim.
    if (dim > 0) {
        if (hidden_dim > dim) hidden_dim /= dim;
        if (vocab_size > dim) vocab_size /= dim;
    } else {
        // No norm found — make a best-effort guess to keep the loader alive.
        dim = if (hidden_dim > 0) hidden_dim / 4 else 16;
        hidden_dim = 4 * dim;
    }
    if (num_layers == 0 or dim == 0) return LoaderError.MissingTensor;

    // Set up an arena to hold all decoded payloads so we free in one shot.
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    // Bucket pages by (layer, kind). Simple O(n²) scan — model page counts
    // are small enough (thousands) that this is fine for the MVP.
    const PageGroupKey = struct { layer: u32, kind: fmt.TensorKind };
    const PageGroup = struct { key: PageGroupKey, page_ids: std.ArrayList(fmt.PageEntry) };

    var groups: std.ArrayList(PageGroup) = .{};
    defer {
        for (groups.items) |*g| g.page_ids.deinit(allocator);
        groups.deinit(allocator);
    }

    for (reader.pages) |p| {
        const key = PageGroupKey{ .layer = p.layer_idx, .kind = p.tensor_kind };
        var found = false;
        for (groups.items) |*g| {
            if (g.key.layer == key.layer and g.key.kind == key.kind) {
                g.page_ids.append(allocator, p) catch return LoaderError.OutOfMemory;
                found = true;
                break;
            }
        }
        if (!found) {
            var list: std.ArrayList(fmt.PageEntry) = .{};
            list.append(allocator, p) catch return LoaderError.OutOfMemory;
            groups.append(allocator, .{ .key = key, .page_ids = list }) catch return LoaderError.OutOfMemory;
        }
    }

    // Decode each group's pages into a contiguous f32 buffer.
    //
    // Multi-page tensors: each page carries its own qio sub-header (for
    // quantized pages) or is a raw byte slice. We decode each page to f32
    // and concatenate the results, so a tensor split across N pages becomes
    // one flat f32 array of length sum(page_elements). The forward path
    // then treats it as a single weight matrix — no paging awareness
    // needed in kernels.zig.
    var decoded: std.ArrayList(DecodedTensor) = .{};
    defer decoded.deinit(allocator);
    var packed_tensors: std.ArrayList(PackedTensor) = .{};
    defer packed_tensors.deinit(allocator);

    // Sort groups by layer so prefetch can look ahead by one layer. Within
    // a layer the kind order doesn't matter for correctness.
    std.sort.heap(@TypeOf(groups.items[0]), groups.items, {}, struct {
        fn lt(_: void, a: @TypeOf(groups.items[0]), b: @TypeOf(groups.items[0])) bool {
            if (a.key.layer != b.key.layer) return a.key.layer < b.key.layer;
            return @intFromEnum(a.key.kind) < @intFromEnum(b.key.kind);
        }
    }.lt);

    for (groups.items, 0..) |g, gi| {
        // P-axis prefetch: while we decode this group's pages, hint the OS
        // to start paging in the NEXT group's pages. madvise(WILLNEED) is
        // async; the kernel overlaps the I/O with our compute. Best-effort
        // — failures are silently ignored.
        if (gi + 1 < groups.items.len) {
            reader.prefetchPages(groups.items[gi + 1].page_ids.items);
        }

        // Sort pages by page_id so concatenation order is stable.
        std.sort.heap(fmt.PageEntry, g.page_ids.items, {}, struct {
            fn lt(_: void, a: fmt.PageEntry, b: fmt.PageEntry) bool {
                return a.page_id < b.page_id;
            }
        }.lt);

        // Compact generation keeps large INT4 matrices in their on-disk
        // representation. Multi-page payloads are merged into one logical
        // packed tensor without ever materializing an F32/F16 copy.
        if (options.compact_int4 and isCompactTensorKind(g.key.kind) and allPagesInt4(g.page_ids.items)) {
            const keep_f32_scales = !use_fp16_scale_cache or
                g.key.kind == .embedding or
                (options.int8_mlp_cache and isMlpTensorKind(g.key.kind));
            const scale_allocator = if (keep_f32_scales) arena_alloc else allocator;
            var int4_data = concatInt4Pages(
                arena_alloc,
                scale_allocator,
                allocator,
                reader,
                g.page_ids.items,
            ) catch |err|
                switch (err) {
                    error.OutOfMemory => return LoaderError.OutOfMemory,
                    else => return LoaderError.BadPayload,
                };
            const transient_scales: []const f32 = if (keep_f32_scales)
                &.{}
            else
                int4_data.scales;
            defer if (transient_scales.len != 0) allocator.free(transient_scales);
            if (options.int8_mlp_cache and isMlpTensorKind(g.key.kind)) {
                int4_data = int4_weights.withExpandedI8(arena_alloc, int4_data) catch
                    return LoaderError.OutOfMemory;
            }
            // Embedding lookup keeps row-major FP32 scales, while the same
            // tensor can also be the tied vocabulary head consumed by the
            // persistent rows4 Q8 executor.
            if (use_fp16_scale_cache) {
                const out_f = packedOutputRows(
                    g.key.kind,
                    int4_data.num_elements,
                    dim,
                    hidden_dim,
                );
                if (out_f != 0 and out_f % 4 == 0) {
                    const in_f = int4_data.num_elements / out_f;
                    if (comptime builtin.cpu.arch == .aarch64) {
                        if (in_f % 16 == 0 and
                            (int4_data.group_size == 8 or int4_data.group_size == 16) and
                            int4_data.expanded_i8.len == 0)
                        {
                            int4_data = int4_weights.withRows4K16Packing(
                                allocator,
                                int4_data,
                                out_f,
                            ) catch return LoaderError.OutOfMemory;
                        }
                    }
                    int4_data = int4_weights.withRows4F16Scales(
                        arena_alloc,
                        int4_data,
                        out_f,
                    ) catch return LoaderError.OutOfMemory;
                } else {
                    int4_data = int4_weights.withF16Scales(arena_alloc, int4_data) catch
                        return LoaderError.OutOfMemory;
                }
                if (!keep_f32_scales) int4_data.scales = &.{};
            }
            try packed_tensors.append(allocator, .{
                .key = .{ .layer = g.key.layer, .kind = g.key.kind },
                .weights = int4_data,
            });
            continue;
        }

        var total_elems: usize = 0;
        for (g.page_ids.items) |p| {
            if (p.row_end < p.row_start) return LoaderError.BadPayload;
            const page_elems = std.math.cast(usize, p.row_end - p.row_start) orelse
                return LoaderError.BadPayload;
            total_elems = std.math.add(usize, total_elems, page_elems) catch
                return LoaderError.BadPayload;
        }

        // Allocate one buffer in the arena and copy all parts in.
        const buf = arena_alloc.alloc(f32, total_elems) catch return LoaderError.OutOfMemory;
        var dst_off: usize = 0;
        for (g.page_ids.items) |p| {
            const part = decodePageF32(allocator, reader, p) catch return LoaderError.BadPayload;
            defer allocator.free(part);
            const expected_len = std.math.cast(usize, p.row_end - p.row_start) orelse
                return LoaderError.BadPayload;
            if (part.len != expected_len) return LoaderError.BadPayload;
            @memcpy(buf[dst_off .. dst_off + part.len], part);
            dst_off += part.len;
        }

        try decoded.append(allocator, .{
            .key = .{ .layer = g.key.layer, .kind = g.key.kind },
            .values = buf,
        });
    }

    // Build per-layer weights. We look up each kind by (layer, kind).
    const layers = allocator.alloc(forward.LayerWeights, num_layers) catch
        return LoaderError.OutOfMemory;
    errdefer allocator.free(layers);

    // Default-empty bias arrays.
    const empty_f32 = try arena_alloc.alloc(f32, 0);

    var layer_idx: u32 = 0;
    while (layer_idx < num_layers) : (layer_idx += 1) {
        const wq_int4 = findPacked(packed_tensors.items, layer_idx, .attn_q);
        const wk_int4 = findPacked(packed_tensors.items, layer_idx, .attn_k);
        const wv_int4 = findPacked(packed_tensors.items, layer_idx, .attn_v);
        const wo_int4 = findPacked(packed_tensors.items, layer_idx, .attn_o);
        const w_gate_int4 = findPacked(packed_tensors.items, layer_idx, .mlp_gate);
        const w_up_int4 = findPacked(packed_tensors.items, layer_idx, .mlp_up);
        const w_down_int4 = findPacked(packed_tensors.items, layer_idx, .mlp_down);

        const wq: []const f32 = findDecoded(decoded.items, layer_idx, .attn_q) orelse
            if (wq_int4 != null) empty_f32 else return LoaderError.MissingTensor;
        const wk: []const f32 = findDecoded(decoded.items, layer_idx, .attn_k) orelse
            if (wk_int4 != null) empty_f32 else return LoaderError.MissingTensor;
        const wv: []const f32 = findDecoded(decoded.items, layer_idx, .attn_v) orelse
            if (wv_int4 != null) empty_f32 else return LoaderError.MissingTensor;
        const wo: []const f32 = findDecoded(decoded.items, layer_idx, .attn_o) orelse
            if (wo_int4 != null) empty_f32 else return LoaderError.MissingTensor;
        const w_gate: []const f32 = findDecoded(decoded.items, layer_idx, .mlp_gate) orelse
            if (w_gate_int4 != null) empty_f32 else return LoaderError.MissingTensor;
        const w_up: []const f32 = findDecoded(decoded.items, layer_idx, .mlp_up) orelse
            if (w_up_int4 != null) empty_f32 else return LoaderError.MissingTensor;
        const w_down: []const f32 = findDecoded(decoded.items, layer_idx, .mlp_down) orelse
            if (w_down_int4 != null) empty_f32 else return LoaderError.MissingTensor;

        layers[layer_idx] = .{
            .input_norm = findDecoded(decoded.items, layer_idx, .input_norm) orelse
                return LoaderError.MissingTensor,
            .wq = wq,
            .wk = wk,
            .wv = wv,
            .wo = wo,
            .wq_f16 = try toF16(arena_alloc, wq),
            .wk_f16 = try toF16(arena_alloc, wk),
            .wv_f16 = try toF16(arena_alloc, wv),
            .wo_f16 = try toF16(arena_alloc, wo),
            .bq = findDecoded(decoded.items, layer_idx, .attn_q_bias) orelse empty_f32,
            .bk = findDecoded(decoded.items, layer_idx, .attn_k_bias) orelse empty_f32,
            .bv = findDecoded(decoded.items, layer_idx, .attn_v_bias) orelse empty_f32,
            .bo = findDecoded(decoded.items, layer_idx, .attn_o_bias) orelse empty_f32,
            .post_attn_norm = findDecoded(decoded.items, layer_idx, .post_attn_norm) orelse
                return LoaderError.MissingTensor,
            .w_gate = w_gate,
            .w_up = w_up,
            .w_down = w_down,
            .w_gate_f16 = try toF16(arena_alloc, w_gate),
            .w_up_f16 = try toF16(arena_alloc, w_up),
            .w_down_f16 = try toF16(arena_alloc, w_down),
            .wq_int4 = wq_int4,
            .wk_int4 = wk_int4,
            .wv_int4 = wv_int4,
            .wo_int4 = wo_int4,
            .w_gate_int4 = w_gate_int4,
            .w_up_int4 = w_up_int4,
            .w_down_int4 = w_down_int4,
        };
    }

    // Note: the converter tags both layer norms as `.norm`; for the MVP we
    // reuse the same norm weight for both pre-attn and post-attn since the
    // fixture only carries one. A real HF model has distinct norm tensors
    // (input_layernorm vs post_attention_layernorm); distinguishing them
    // needs a richer name classifier and lands with real-model support.

    // Global tensors: final norm + embedding. lm_head may be tied to the
    // embedding (Qwen2.5/Llama3 set tie_word_embeddings=true), in which
    // case there is no separate lm_head.weight in the checkpoint.
    const final_norm = findDecoded(decoded.items, 0, .final_norm) orelse
        return LoaderError.MissingTensor;
    const embedding_int4 = findPacked(packed_tensors.items, 0, .embedding);
    const embedding: []const f32 = findDecoded(decoded.items, 0, .embedding) orelse
        if (embedding_int4 != null) empty_f32 else return LoaderError.MissingTensor;
    const tie = override.tie_word_embeddings orelse false;
    const lm_head_int4 = if (tie) embedding_int4 else findPacked(packed_tensors.items, 0, .lm_head);
    const lm_head: []const f32 = if (tie)
        embedding
    else
        (findDecoded(decoded.items, 0, .lm_head) orelse
            if (lm_head_int4 != null) empty_f32 else return LoaderError.MissingTensor);

    // Apply JSON sidecar overrides on top of the page-metadata heuristics.
    const final_dim = override.dim orelse dim;
    const final_hidden = override.hidden_dim orelse hidden_dim;
    const final_layers = override.num_layers orelse num_layers;
    const final_vocab = override.vocab_size orelse vocab_size;
    const final_rms_eps = override.rms_eps orelse 1e-6;
    const final_rope_theta = override.rope_theta orelse 10000.0;
    const final_num_heads = override.num_heads orelse blk: {
        const hd: usize = 64;
        if (final_dim >= hd and final_dim % hd == 0) break :blk final_dim / hd;
        break :blk 1;
    };
    const final_head_dim = override.head_dim orelse blk: {
        const hd: usize = 64;
        if (final_dim >= hd and final_dim % hd == 0) break :blk hd;
        break :blk final_dim;
    };
    const final_num_kv_heads = override.num_kv_heads orelse final_num_heads;

    return .{
        .allocator = allocator,
        .config = .{
            .dim = final_dim,
            .hidden_dim = final_hidden,
            .num_layers = final_layers,
            .vocab_size = final_vocab,
            .num_heads = final_num_heads,
            .head_dim = final_head_dim,
            .rms_eps = final_rms_eps,
            .rope_theta = final_rope_theta,
            .num_kv_heads = final_num_kv_heads,
            .tie_word_embeddings = tie,
        },
        .source_fingerprint = source_fingerprint,
        .layers = layers,
        .weights_arena = arena,
        .final_norm = final_norm,
        .lm_head = lm_head,
        .lm_head_int4 = lm_head_int4,
        .token_embedding = embedding,
        .token_embedding_int4 = embedding_int4,
    };
}

/// A decoded tensor — flat f32 values grouped by (layer, kind).
const DecodedTensor = struct {
    key: struct { layer: u32, kind: fmt.TensorKind },
    values: []const f32,
};

const PackedTensor = struct {
    key: struct { layer: u32, kind: fmt.TensorKind },
    weights: int4_weights.Int4WeightData,
};

fn findPacked(tensors: []const PackedTensor, layer: u32, kind: fmt.TensorKind) ?int4_weights.Int4WeightData {
    for (tensors) |t| {
        if (t.key.layer == layer and t.key.kind == kind) return t.weights;
    }
    return null;
}

fn toF16(arena_alloc: std.mem.Allocator, values: []const f32) LoaderError![]const f16 {
    if (values.len == 0) return &.{};
    const out = arena_alloc.alloc(f16, values.len) catch return LoaderError.OutOfMemory;
    for (values, out) |src, *dst| dst.* = @floatCast(src);
    return out;
}

fn isCompactTensorKind(kind: fmt.TensorKind) bool {
    return switch (kind) {
        .embedding,
        .attn_q,
        .attn_k,
        .attn_v,
        .attn_o,
        .mlp_gate,
        .mlp_up,
        .mlp_down,
        .lm_head,
        => true,
        else => false,
    };
}

fn packedOutputRows(
    kind: fmt.TensorKind,
    num_elements: usize,
    dim: usize,
    hidden_dim: usize,
) usize {
    const in_f = if (kind == .mlp_down) hidden_dim else dim;
    if (in_f == 0 or num_elements % in_f != 0) return 0;
    return num_elements / in_f;
}

fn isMlpTensorKind(kind: fmt.TensorKind) bool {
    return switch (kind) {
        .mlp_gate, .mlp_up, .mlp_down => true,
        else => false,
    };
}

fn allPagesInt4(pages: []const fmt.PageEntry) bool {
    if (pages.len == 0) return false;
    for (pages) |page| if (page.precision != .int4) return false;
    return true;
}

/// Merge independently quantized pages into one logical INT4 tensor.
/// The converter aligns every non-final page to a quantization-group
/// boundary, so concatenating scales preserves the global group index.
fn concatInt4Pages(
    arena_alloc: std.mem.Allocator,
    scales_alloc: std.mem.Allocator,
    allocator: std.mem.Allocator,
    reader: *fmt.FileReader,
    pages: []const fmt.PageEntry,
) !int4_weights.Int4WeightData {
    if (pages.len == 0) return error.BadPayload;
    const qio = @import("model/qio.zig");

    var group_size: u32 = 0;
    var total_elements: usize = 0;
    var total_scales: usize = 0;
    var max_payload_bytes: usize = 0;
    for (pages, 0..) |page, page_idx| {
        if (page.precision != .int4 or page.quant_group == 0 or
            page.row_end < page.row_start)
            return error.BadPayload;
        const page_group_size: u32 = page.quant_group;
        if (group_size == 0) group_size = page_group_size;
        if (page_group_size != group_size) return error.BadPayload;
        const group_size_usize: usize = group_size;
        const page_elements = std.math.cast(usize, page.row_end - page.row_start) orelse
            return error.BadPayload;
        if (page_idx + 1 < pages.len and page_elements % group_size_usize != 0)
            return error.BadPayload;
        const page_scales = ceilDiv(page_elements, group_size_usize);
        const scales_bytes = try std.math.mul(usize, page_scales, @sizeOf(f32));
        const packed_bytes = ceilDiv(page_elements, 2);
        const header_and_scales = try std.math.add(usize, qio.SUB_HEADER_SIZE, scales_bytes);
        const expected_payload = try std.math.add(
            usize,
            header_and_scales,
            packed_bytes,
        );
        const payload_bytes = std.math.cast(usize, page.data_len) orelse
            return error.BadPayload;
        if (payload_bytes != expected_payload) return error.BadPayload;
        max_payload_bytes = @max(max_payload_bytes, payload_bytes);
        total_elements = try std.math.add(usize, total_elements, page_elements);
        total_scales = try std.math.add(usize, total_scales, page_scales);
    }
    const expected_scales = ceilDiv(total_elements, @as(usize, group_size));
    if (total_scales != expected_scales) return error.BadPayload;

    const packed_out = try arena_alloc.alloc(u8, ceilDiv(total_elements, 2));
    @memset(packed_out, 0);
    const scales_out = try scales_alloc.alloc(f32, total_scales);
    const payload_scratch = try allocator.alloc(u8, max_payload_bytes);
    defer allocator.free(payload_scratch);

    var dst_element: usize = 0;
    var dst_scale: usize = 0;
    for (pages) |page| {
        const payload_len = std.math.cast(usize, page.data_len) orelse
            return error.BadPayload;
        const payload = payload_scratch[0..payload_len];
        try reader.readPage(page, payload);
        const hdr = try qio.readQuantHeader(payload);
        const page_elements: usize = hdr.num_elements;
        const metadata_elements = std.math.cast(usize, page.row_end - page.row_start) orelse
            return error.BadPayload;
        if (hdr.precision != .int4 or hdr.group_size != group_size or
            page_elements != metadata_elements)
            return error.BadPayload;
        const page_scales: usize = ceilDiv(page_elements, @as(usize, hdr.group_size));
        const scales_bytes = try std.math.mul(usize, page_scales, @sizeOf(f32));
        const packed_offset = try std.math.add(usize, qio.SUB_HEADER_SIZE, scales_bytes);
        const page_packed_len = (page_elements + 1) / 2;
        if (payload.len < packed_offset or payload.len - packed_offset < page_packed_len) return error.BadPayload;

        for (0..page_scales) |scale_idx| {
            const off = qio.SUB_HEADER_SIZE + scale_idx * @sizeOf(f32);
            scales_out[dst_scale + scale_idx] = @bitCast(std.mem.readInt(u32, payload[off..][0..4], .little));
        }
        const page_packed = payload[packed_offset .. packed_offset + page_packed_len];
        if (dst_element % 2 == 0 and page_elements % 2 == 0) {
            @memcpy(packed_out[dst_element / 2 .. dst_element / 2 + page_packed_len], page_packed);
        } else {
            for (0..page_elements) |src_idx| {
                writeInt4Nibble(packed_out, dst_element + src_idx, readInt4Nibble(page_packed, src_idx));
            }
        }
        dst_element += page_elements;
        dst_scale += page_scales;
    }
    if (dst_element != total_elements or dst_scale != total_scales) return error.BadPayload;

    return .{
        .packed_bytes = packed_out,
        .scales = scales_out,
        .group_size = group_size,
        .num_elements = total_elements,
    };
}

inline fn readInt4Nibble(bytes: []const u8, idx: usize) u8 {
    const byte = bytes[idx / 2];
    return if (idx & 1 == 0) byte & 0x0F else (byte >> 4) & 0x0F;
}

inline fn writeInt4Nibble(bytes: []u8, idx: usize, value: u8) void {
    const byte_idx = idx / 2;
    if (idx & 1 == 0) {
        bytes[byte_idx] = (bytes[byte_idx] & 0xF0) | (value & 0x0F);
    } else {
        bytes[byte_idx] = (bytes[byte_idx] & 0x0F) | ((value & 0x0F) << 4);
    }
}

inline fn ceilDiv(numerator: usize, denominator: usize) usize {
    return numerator / denominator + @intFromBool(numerator % denominator != 0);
}

fn findDecoded(tensors: []const DecodedTensor, layer: u32, kind: fmt.TensorKind) ?[]const f32 {
    for (tensors) |t| {
        if (t.key.layer == layer and t.key.kind == kind) return t.values;
    }
    return null;
}

/// Decode one page to a flat f32 buffer (caller owns). Handles both qio
/// quantized payloads and raw FP32/FP16 byte slices.
fn decodePageF32(
    allocator: std.mem.Allocator,
    reader: *fmt.FileReader,
    page: fmt.PageEntry,
) ![]f32 {
    const raw = try reader.readPageAlloc(page);
    defer allocator.free(raw);

    // Detect qio quantized vs raw by the magic in the first 4 bytes.
    const qio_mod = @import("model/qio.zig");
    if (raw.len >= 4 and std.mem.readInt(u32, raw[0..4], .little) == qio_mod.PAYLOAD_MAGIC) {
        return try qio_mod.decodePage(f32, allocator, raw);
    }

    // Raw bytes — interpret by stored precision.
    switch (page.precision) {
        .fp16 => {
            // IEEE FP16: sign(1) + exp(5) + mant(10).
            if (raw.len % 2 != 0) return error.BadPayload;
            const n = raw.len / 2;
            const out = try allocator.alloc(f32, n);
            errdefer allocator.free(out);
            const f16bits = @import("core").f16bits;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const bits = std.mem.readInt(u16, raw[i * 2 ..][0..2], .little);
                out[i] = f16bits.f16BitsToF32(bits);
            }
            return out;
        },
        .bf16 => {
            // BF16: sign(1) + exp(8) + mant(7) — top 16 bits of an FP32.
            // Decode by placing the bits into the high half of a u32.
            if (raw.len % 2 != 0) return error.BadPayload;
            const n = raw.len / 2;
            const out = try allocator.alloc(f32, n);
            errdefer allocator.free(out);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const bits = std.mem.readInt(u16, raw[i * 2 ..][0..2], .little);
                const f32_bits: u32 = @as(u32, bits) << 16;
                out[i] = @bitCast(f32_bits);
            }
            return out;
        },
        .fp32 => {
            if (raw.len % @sizeOf(f32) != 0) return error.BadPayload;
            const n = raw.len / @sizeOf(f32);
            const out = try allocator.alloc(f32, n);
            errdefer allocator.free(out);
            const src: [*]const f32 = @ptrCast(@alignCast(raw.ptr));
            @memcpy(out, src[0..n]);
            return out;
        },
        else => {},
    }

    // Fallback: assume raw FP32.
    if (raw.len % @sizeOf(f32) != 0) return error.BadPayload;
    const n = raw.len / @sizeOf(f32);
    const out = try allocator.alloc(f32, n);
    errdefer allocator.free(out);
    const src: [*]const f32 = @ptrCast(@alignCast(raw.ptr));
    @memcpy(out, src[0..n]);
    return out;
}

test "prepared record schema rejects extra layer and global tensors" {
    const testing = std.testing;
    var config: ModelConfig = .{
        .dim = 16,
        .hidden_dim = 32,
        .num_layers = 1,
        .vocab_size = 64,
        .num_heads = 2,
        .head_dim = 8,
        .num_kv_heads = 1,
        .tie_word_embeddings = true,
    };
    try testing.expect(isExpectedPreparedRecord(config, 0, .attn_q, .tensor));
    try testing.expect(!isExpectedPreparedRecord(config, 1, .attn_q, .tensor));
    try testing.expect(!isExpectedPreparedRecord(
        config,
        runtime_image.GLOBAL_LAYER,
        .attn_q,
        .tensor,
    ));
    try testing.expect(!isExpectedPreparedRecord(
        config,
        runtime_image.GLOBAL_LAYER,
        .lm_head,
        .tensor,
    ));
    config.tie_word_embeddings = false;
    try testing.expect(isExpectedPreparedRecord(
        config,
        runtime_image.GLOBAL_LAYER,
        .lm_head,
        .tensor,
    ));
    try testing.expect(isExpectedPreparedRecord(
        config,
        0,
        .other,
        .mlp_gate_up_pair,
    ));
    try testing.expect(isExpectedPreparedRecord(
        config,
        0,
        .mlp_gate,
        .mlp_gate_up_pair,
    ));
    try testing.expect(isExpectedPreparedRecord(
        config,
        0,
        .attn_q,
        .mlp_gate_up_pair,
    ));
    try testing.expect(!isExpectedPreparedRecord(
        config,
        runtime_image.GLOBAL_LAYER,
        .mlp_gate,
        .mlp_gate_up_pair,
    ));
}

fn testPreparedInt4Weights(
    allocator: std.mem.Allocator,
    out_f: usize,
    in_f: usize,
    layout: int4_weights.PackedLayout,
    seed: u8,
) !int4_weights.Int4WeightData {
    return testPreparedInt4WeightsWithGroup(
        allocator,
        out_f,
        in_f,
        layout,
        seed,
        8,
    );
}

fn testPreparedInt4WeightsWithGroup(
    allocator: std.mem.Allocator,
    out_f: usize,
    in_f: usize,
    layout: int4_weights.PackedLayout,
    seed: u8,
    group_size: u32,
) !int4_weights.Int4WeightData {
    const num_elements = try std.math.mul(usize, out_f, in_f);
    if (group_size == 0) return error.InvalidShape;
    if (num_elements % group_size != 0) return error.InvalidShape;
    const packed_bytes = try allocator.alloc(u8, ceilDiv(num_elements, 2));
    for (packed_bytes, 0..) |*byte, index| {
        const lane: u8 = @intCast(index & 0x0f);
        const low = (seed +% lane *% 3) & 0x0f;
        const high = (seed +% lane *% 5 +% 1) & 0x0f;
        byte.* = low | (high << 4);
    }
    const scale_count = num_elements / group_size;
    return switch (layout) {
        .row_major => blk: {
            const scales = try allocator.alloc(f32, scale_count);
            for (scales, 0..) |*scale, index| {
                scale.* = @as(f32, @floatFromInt((seed & 7) + 1)) +
                    @as(f32, @floatFromInt(index)) / 32.0;
            }
            break :blk .{
                .packed_bytes = packed_bytes,
                .scales = scales,
                .group_size = group_size,
                .num_elements = num_elements,
                .packed_layout = .row_major,
            };
        },
        .rows4_k16 => blk: {
            if (out_f % 4 != 0 or in_f % 16 != 0)
                return error.InvalidShape;
            const scales = try allocator.alloc(f16, scale_count);
            for (scales, 0..) |*scale, index| {
                scale.* = @floatCast(
                    @as(f32, @floatFromInt((seed & 7) + 1)) +
                        @as(f32, @floatFromInt(index)) / 32.0,
                );
            }
            break :blk .{
                .packed_bytes = packed_bytes,
                .scales = &.{},
                .scales_f16_rows4 = scales,
                .group_size = group_size,
                .num_elements = num_elements,
                .packed_layout = .rows4_k16,
            };
        },
    };
}

fn testPreparedModel(
    allocator: std.mem.Allocator,
    num_layers: usize,
) !LoadedModel {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    const layers = try allocator.alloc(forward.LayerWeights, num_layers);
    errdefer allocator.free(layers);

    const dim: usize = 16;
    const hidden_dim: usize = 4;
    const vocab_size: usize = 16;
    for (layers, 0..) |*layer, layer_index| {
        const input_norm = try arena_allocator.alloc(f32, dim);
        const post_attn_norm = try arena_allocator.alloc(f32, dim);
        @memset(input_norm, 1.0);
        @memset(post_attn_norm, 0.75);
        const layer_seed: u8 = @intCast(layer_index * 17);
        layer.* = .{
            .input_norm = input_norm,
            .wq = &.{},
            .wk = &.{},
            .wv = &.{},
            .wo = &.{},
            .bq = &.{},
            .bk = &.{},
            .bv = &.{},
            .bo = &.{},
            .post_attn_norm = post_attn_norm,
            .w_gate = &.{},
            .w_up = &.{},
            .w_down = &.{},
            .wq_int4 = try testPreparedInt4Weights(arena_allocator, dim, dim, .row_major, layer_seed +% 1),
            .wk_int4 = try testPreparedInt4Weights(arena_allocator, dim, dim, .row_major, layer_seed +% 2),
            .wv_int4 = try testPreparedInt4Weights(arena_allocator, dim, dim, .row_major, layer_seed +% 3),
            .wo_int4 = try testPreparedInt4Weights(arena_allocator, dim, dim, .row_major, layer_seed +% 4),
            .w_gate_int4 = try testPreparedInt4Weights(arena_allocator, hidden_dim, dim, .rows4_k16, layer_seed +% 5),
            .w_up_int4 = try testPreparedInt4Weights(arena_allocator, hidden_dim, dim, .rows4_k16, layer_seed +% 9),
            .w_down_int4 = try testPreparedInt4Weights(arena_allocator, dim, hidden_dim, .row_major, layer_seed +% 13),
        };
    }

    const final_norm = try arena_allocator.alloc(f32, dim);
    @memset(final_norm, 1.0);
    const token_embedding_int4 = try testPreparedInt4Weights(
        arena_allocator,
        vocab_size,
        dim,
        .row_major,
        0x31,
    );
    return .{
        .allocator = allocator,
        .config = .{
            .dim = dim,
            .hidden_dim = hidden_dim,
            .num_layers = num_layers,
            .vocab_size = vocab_size,
            .num_heads = 1,
            .head_dim = dim,
            .num_kv_heads = 1,
            .tie_word_embeddings = true,
        },
        .source_fingerprint = runtime_image.fingerprint("test-prepared-source"),
        .layers = layers,
        .weights_arena = arena,
        .final_norm = final_norm,
        .lm_head = &.{},
        .token_embedding = &.{},
        .token_embedding_int4 = token_embedding_int4,
    };
}

fn testMappedWriteRecord(
    image: *const runtime_image.MappedImage,
    record: runtime_image.Record,
) !runtime_image.WriteRecord {
    return .{
        .key = record.key,
        .role = record.role,
        .encoding = record.encoding,
        .packed_layout = record.packed_layout,
        .pair_nibble_layout = record.pair_nibble_layout,
        .group_size = record.group_size,
        .out_f = record.out_f,
        .in_f = record.in_f,
        .num_elements = record.num_elements,
        .flags = record.flags,
        .packed_bytes = try image.bytes(record, .packed_weights),
        .scales_f32 = try image.bytes(record, .scales_f32),
        .scales_f16 = try image.bytes(record, .scales_f16),
        .scales_f16_rows4 = try image.bytes(record, .scales_f16_rows4),
        .raw = try image.bytes(record, .raw),
    };
}

fn testNibble(bytes: []const u8, index: usize) u8 {
    return if (index & 1 == 0)
        bytes[index / 2] & 0x0f
    else
        bytes[index / 2] >> 4;
}

fn testTmpPath(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    name: []const u8,
) ![]u8 {
    const root = try dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, name });
}

/// Convert a separate-only v2 fixture into the frozen read-only v1 container
/// without changing any payload ranges. Keeping the v2 data offset is valid:
/// v1 requires only an aligned non-overlapping index/data boundary.
fn testRewriteSeparateV2AsV1(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    v2_name: []const u8,
    v1_name: []const u8,
) !void {
    var image = try runtime_image.MappedImage.openAt(dir, v2_name);
    defer image.close();
    const file_size = std.math.cast(usize, image.header.file_size) orelse
        return error.FileTooLarge;
    const data_offset = std.math.cast(usize, image.header.data_offset) orelse
        return error.FileTooLarge;
    const record_count = image.recordCount();
    const v1_index_len = try std.math.mul(
        usize,
        record_count,
        runtime_image.V1_RECORD_SIZE,
    );

    const bytes = try allocator.alloc(u8, file_size);
    defer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..runtime_image.HEADER_SIZE], image.mapped[0..runtime_image.HEADER_SIZE]);
    @memcpy(bytes[data_offset..file_size], image.mapped[data_offset..file_size]);
    for (0..record_count) |record_index| {
        const source = runtime_image.HEADER_SIZE +
            record_index * runtime_image.RECORD_SIZE;
        const destination = runtime_image.HEADER_SIZE +
            record_index * runtime_image.V1_RECORD_SIZE;
        // V1 shares descriptor bytes 0..120. Bytes 120..128 are reserved and
        // replace the v2 role/layout fields; per-record SHA-256 is absent.
        @memcpy(bytes[destination..][0..120], image.mapped[source..][0..120]);
    }

    std.mem.writeInt(u16, bytes[4..6], @intFromEnum(runtime_image.Version.v1), .little);
    std.mem.writeInt(u16, bytes[8..10], runtime_image.V1_RECORD_SIZE, .little);
    @memcpy(bytes[80..112], &runtime_image.ABI_FINGERPRINT_V1);
    const index_crc = std.hash.Crc32.hash(
        bytes[runtime_image.HEADER_SIZE..][0..v1_index_len],
    );
    std.mem.writeInt(u32, bytes[152..156], index_crc, .little);
    @memset(bytes[156..160], 0);
    const header_crc = std.hash.Crc32.hash(bytes[0..runtime_image.HEADER_SIZE]);
    std.mem.writeInt(u32, bytes[156..160], header_crc, .little);

    try dir.writeFile(.{ .sub_path = v1_name, .data = bytes });
}

test "pair-required writer emits one lossless record per layer and loader borrows it" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testTmpPath(testing.allocator, tmp.dir, "pair-full.glrt");
    defer testing.allocator.free(path);

    var model = try testPreparedModel(testing.allocator, 2);
    defer model.deinit();
    const fingerprint = runtime_image.fingerprint("pair-full-fingerprint");
    const write_stats = try writePreparedWithOptionsAndStats(
        testing.allocator,
        &model,
        path,
        fingerprint,
        .{ .mlp_layout = .pair_nibble_required },
    );
    const pair_elements = model.config.hidden_dim * model.config.dim;
    const pair_scale_bytes = 2 * (pair_elements / 8) * @sizeOf(f16);
    const per_layer_workspace = pair_elements + pair_scale_bytes;
    try testing.expectEqual(
        @as(u64, model.config.num_layers),
        write_stats.generated_records,
    );
    try testing.expectEqual(
        @as(u64, model.config.num_layers * per_layer_workspace),
        write_stats.generated_workspace_bytes_total,
    );
    try testing.expectEqual(
        @as(u64, per_layer_workspace),
        write_stats.generated_workspace_bytes_peak,
    );

    var image = try runtime_image.MappedImage.open(path);
    defer image.close();
    // Per layer: two norms, four attention matrices, one pair, and down.
    // Globals: final norm and tied embedding.
    try testing.expectEqual(@as(usize, 2 * 8 + 2), image.recordCount());
    var total_pairs: usize = 0;
    for (0..image.recordCount()) |record_index| {
        const record = try image.recordAt(record_index);
        if (record.role == .mlp_gate_up_pair) total_pairs += 1;
        try testing.expect(!(record.role == .tensor and
            (record.key.kind == .mlp_gate or record.key.kind == .mlp_up)));
    }
    try testing.expectEqual(model.config.num_layers, total_pairs);

    for (model.layers, 0..) |source_layer, layer_index| {
        const layer_idx: u32 = @intCast(layer_index);
        const pair = (try inspectPreparedPairNibble(
            &image,
            layer_idx,
            model.config.hidden_dim,
            model.config.dim,
        )) orelse return error.MissingTensor;
        const gate = source_layer.w_gate_int4 orelse return error.MissingTensor;
        const up = source_layer.w_up_int4 orelse return error.MissingTensor;
        try testing.expectEqual(gate.num_elements, pair.paired_bytes.len);
        for (pair.paired_bytes, 0..) |actual, physical_index| {
            const expected = testNibble(gate.packed_bytes, physical_index) |
                (testNibble(up.packed_bytes, physical_index) << 4);
            try testing.expectEqual(expected, actual);
        }
        const groups_per_row = model.config.dim / gate.group_size;
        for (0..model.config.hidden_dim / 4) |tile| {
            for (0..groups_per_row) |group| {
                const source = (tile * groups_per_row + group) * 4;
                const destination = (tile * groups_per_row + group) * 8;
                try testing.expectEqualSlices(
                    u8,
                    std.mem.sliceAsBytes(gate.scales_f16_rows4[source..][0..4]),
                    std.mem.sliceAsBytes(pair.scales_f16_pairs[destination..][0..4]),
                );
                try testing.expectEqualSlices(
                    u8,
                    std.mem.sliceAsBytes(up.scales_f16_rows4[source..][0..4]),
                    std.mem.sliceAsBytes(pair.scales_f16_pairs[destination + 4 ..][0..4]),
                );
            }
        }
    }

    try testing.expectError(
        LoaderError.PreparedMlpLayoutMismatch,
        loadPreparedWithOptions(testing.allocator, path, .{
            .mlp_layout = .separate_required,
        }),
    );
    var auto_loaded = try loadPrepared(testing.allocator, path);
    try testing.expectEqual(
        PreparedMlpLayout.pair_nibble,
        auto_loaded.prepared_mlp_layout.?,
    );
    auto_loaded.deinit();
    var loaded = try loadPreparedWithOptions(testing.allocator, path, .{
        .mlp_layout = .pair_nibble_required,
    });
    defer loaded.deinit();
    try testing.expectEqual(
        PreparedMlpLayout.pair_nibble,
        loaded.prepared_mlp_layout.?,
    );
    for (loaded.layers) |layer| {
        try testing.expect(layer.w_gate_int4 == null);
        try testing.expect(layer.w_up_int4 == null);
        const pair = layer.w_gate_up_pair_int4 orelse return error.MissingTensor;
        const mapped = &loaded.prepared_image.?;
        const map_start = @intFromPtr(mapped.mapped.ptr);
        const map_end = map_start + mapped.mapped.len;
        const pair_start = @intFromPtr(pair.paired_bytes.ptr);
        const scale_start = @intFromPtr(pair.scales_f16_pairs.ptr);
        try testing.expect(pair_start >= map_start and
            pair_start + pair.paired_bytes.len <= map_end);
        try testing.expect(scale_start >= map_start and
            scale_start + std.mem.sliceAsBytes(pair.scales_f16_pairs).len <= map_end);
    }
}

test "pair-required writer preserves g16 branch bytes and scale order" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testTmpPath(testing.allocator, tmp.dir, "pair-g16.glrt");
    defer testing.allocator.free(path);

    var model = try testPreparedModel(testing.allocator, 1);
    defer model.deinit();
    const arena_allocator = model.weights_arena.allocator();
    model.layers[0].w_gate_int4 = try testPreparedInt4WeightsWithGroup(
        arena_allocator,
        model.config.hidden_dim,
        model.config.dim,
        .rows4_k16,
        0x42,
        16,
    );
    model.layers[0].w_up_int4 = try testPreparedInt4WeightsWithGroup(
        arena_allocator,
        model.config.hidden_dim,
        model.config.dim,
        .rows4_k16,
        0x69,
        16,
    );
    try writePreparedWithOptions(
        testing.allocator,
        &model,
        path,
        runtime_image.fingerprint("pair-g16"),
        .{ .mlp_layout = .pair_nibble_required },
    );

    var loaded = try loadPreparedWithOptions(testing.allocator, path, .{
        .mlp_layout = .pair_nibble_required,
    });
    defer loaded.deinit();
    const pair = loaded.layers[0].w_gate_up_pair_int4 orelse
        return error.MissingTensor;
    const gate = model.layers[0].w_gate_int4.?;
    const up = model.layers[0].w_up_int4.?;
    try testing.expectEqual(@as(u32, 16), pair.group_size);
    for (pair.paired_bytes, 0..) |actual, physical_index| {
        try testing.expectEqual(
            testNibble(gate.packed_bytes, physical_index) |
                (testNibble(up.packed_bytes, physical_index) << 4),
            actual,
        );
    }
    try testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(gate.scales_f16_rows4[0..4]),
        std.mem.sliceAsBytes(pair.scales_f16_pairs[0..4]),
    );
    try testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(up.scales_f16_rows4[0..4]),
        std.mem.sliceAsBytes(pair.scales_f16_pairs[4..8]),
    );
}

test "prepared writer rewrites pair-only sources and rejects ambiguous source residency" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const original_path = try testTmpPath(testing.allocator, tmp.dir, "pair-original.glrt");
    defer testing.allocator.free(original_path);
    const rewrite_path = try testTmpPath(testing.allocator, tmp.dir, "pair-rewrite.glrt");
    defer testing.allocator.free(rewrite_path);

    var separate_model = try testPreparedModel(testing.allocator, 2);
    defer separate_model.deinit();
    try writePreparedWithOptions(
        testing.allocator,
        &separate_model,
        original_path,
        runtime_image.fingerprint("pair-original"),
        .{ .mlp_layout = .pair_nibble_required },
    );
    var pair_model = try loadPreparedWithOptions(testing.allocator, original_path, .{
        .mlp_layout = .pair_nibble_required,
    });
    defer pair_model.deinit();
    try writePreparedWithOptions(
        testing.allocator,
        &pair_model,
        rewrite_path,
        runtime_image.fingerprint("pair-original"),
        .{ .mlp_layout = .pair_nibble_required },
    );

    const original_bytes = try tmp.dir.readFileAlloc(
        testing.allocator,
        "pair-original.glrt",
        1024 * 1024,
    );
    defer testing.allocator.free(original_bytes);
    const rewrite_bytes = try tmp.dir.readFileAlloc(
        testing.allocator,
        "pair-rewrite.glrt",
        1024 * 1024,
    );
    defer testing.allocator.free(rewrite_bytes);
    try testing.expectEqualSlices(u8, original_bytes, rewrite_bytes);

    var original = try runtime_image.MappedImage.open(original_path);
    defer original.close();
    var rewrite = try runtime_image.MappedImage.open(rewrite_path);
    defer rewrite.close();
    for (0..separate_model.config.num_layers) |layer_index| {
        const layer_idx: u32 = @intCast(layer_index);
        const original_record = original.findRole(layer_idx, .mlp_gate_up_pair) orelse
            return error.MissingTensor;
        const rewrite_record = rewrite.findRole(layer_idx, .mlp_gate_up_pair) orelse
            return error.MissingTensor;
        try testing.expectEqualSlices(
            u8,
            try original.bytes(original_record, .packed_weights),
            try rewrite.bytes(rewrite_record, .packed_weights),
        );
        try testing.expectEqualSlices(
            u8,
            try original.bytes(original_record, .scales_f16_rows4),
            try rewrite.bytes(rewrite_record, .scales_f16_rows4),
        );
    }

    const separate_from_pair_path = try testTmpPath(
        testing.allocator,
        tmp.dir,
        "separate-from-pair.glrt",
    );
    defer testing.allocator.free(separate_from_pair_path);
    try testing.expectError(
        LoaderError.PreparedMlpLayoutMismatch,
        writePrepared(
            testing.allocator,
            &pair_model,
            separate_from_pair_path,
            runtime_image.fingerprint("separate-from-pair"),
        ),
    );

    const ambiguous_path = try testTmpPath(testing.allocator, tmp.dir, "ambiguous.glrt");
    defer testing.allocator.free(ambiguous_path);
    pair_model.layers[0].w_gate_int4 = pair_model.layers[0].w_down_int4;
    try testing.expectError(
        LoaderError.BadPayload,
        writePreparedWithOptions(
            testing.allocator,
            &pair_model,
            ambiguous_path,
            runtime_image.fingerprint("ambiguous"),
            .{ .mlp_layout = .pair_nibble_required },
        ),
    );
    pair_model.layers[0].w_gate_int4 = null;

    const saved_gate = separate_model.layers[0].w_gate_int4;
    const saved_up = separate_model.layers[0].w_up_int4;
    separate_model.layers[0].w_gate_int4 = null;
    separate_model.layers[0].w_up_int4 = null;
    separate_model.layers[0].w_gate_up_pair_int4 =
        pair_model.layers[0].w_gate_up_pair_int4;
    const mixed_source_path = try testTmpPath(
        testing.allocator,
        tmp.dir,
        "mixed-source.glrt",
    );
    defer testing.allocator.free(mixed_source_path);
    try testing.expectError(
        LoaderError.BadPayload,
        writePreparedWithOptions(
            testing.allocator,
            &separate_model,
            mixed_source_path,
            runtime_image.fingerprint("mixed-source"),
            .{ .mlp_layout = .pair_nibble_required },
        ),
    );

    separate_model.layers[0].w_gate_up_pair_int4 = null;
    separate_model.layers[0].w_gate_int4 = saved_gate;
    separate_model.layers[0].w_up_int4 = saved_up;
    separate_model.layers[1].w_up_int4 = null;
    const partial_source_path = try testTmpPath(
        testing.allocator,
        tmp.dir,
        "partial-source.glrt",
    );
    defer testing.allocator.free(partial_source_path);
    try testing.expectError(
        LoaderError.MissingTensor,
        writePreparedWithOptions(
            testing.allocator,
            &separate_model,
            partial_source_path,
            runtime_image.fingerprint("partial-source"),
            .{ .mlp_layout = .pair_nibble_required },
        ),
    );
}

test "default prepared writer remains separate and strict pair policy never falls back" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testTmpPath(testing.allocator, tmp.dir, "separate-full.glrt");
    defer testing.allocator.free(path);

    var model = try testPreparedModel(testing.allocator, 1);
    defer model.deinit();
    try writePrepared(
        testing.allocator,
        &model,
        path,
        runtime_image.fingerprint("separate-full-fingerprint"),
    );

    var image = try runtime_image.MappedImage.open(path);
    defer image.close();
    try testing.expect(image.findRole(0, .mlp_gate_up_pair) == null);
    const gate_record = image.find(0, .mlp_gate) orelse return error.MissingTensor;
    const up_record = image.find(0, .mlp_up) orelse return error.MissingTensor;
    const gate = try preparedInt4(&image, 0, .mlp_gate, 4, 16, false);
    const up = try preparedInt4(&image, 0, .mlp_up, 4, 16, false);
    try testing.expectEqual(runtime_image.Encoding.int4, gate_record.encoding);
    try testing.expectEqual(runtime_image.Encoding.int4, up_record.encoding);
    try testing.expectEqualSlices(
        u8,
        model.layers[0].w_gate_int4.?.packed_bytes,
        gate.packed_bytes,
    );
    try testing.expectEqualSlices(
        u8,
        model.layers[0].w_up_int4.?.packed_bytes,
        up.packed_bytes,
    );
    try testing.expectError(
        LoaderError.PreparedMlpLayoutMismatch,
        loadPreparedWithOptions(testing.allocator, path, .{
            .mlp_layout = .pair_nibble_required,
        }),
    );

    var auto_loaded = try loadPrepared(testing.allocator, path);
    try testing.expectEqual(
        PreparedMlpLayout.separate,
        auto_loaded.prepared_mlp_layout.?,
    );
    auto_loaded.deinit();

    var loaded = try loadPreparedWithOptions(testing.allocator, path, .{
        .mlp_layout = .separate_required,
    });
    defer loaded.deinit();
    try testing.expectEqual(
        PreparedMlpLayout.separate,
        loaded.prepared_mlp_layout.?,
    );
    try testing.expect(loaded.layers[0].w_gate_int4 != null);
    try testing.expect(loaded.layers[0].w_up_int4 != null);
    try testing.expect(loaded.layers[0].w_gate_up_pair_int4 == null);

    // A pair-required write rejects incompatible geometry and does not emit a
    // legacy artifact as a convenience fallback.
    model.layers[0].w_gate_int4.?.packed_layout = .row_major;
    const invalid_path = try testTmpPath(testing.allocator, tmp.dir, "no-fallback.glrt");
    defer testing.allocator.free(invalid_path);
    const prior_destination = "prior-valid-destination";
    try tmp.dir.writeFile(.{
        .sub_path = "no-fallback.glrt",
        .data = prior_destination,
    });
    try testing.expectError(
        LoaderError.BadPayload,
        writePreparedWithOptions(
            testing.allocator,
            &model,
            invalid_path,
            runtime_image.fingerprint("no-fallback"),
            .{ .mlp_layout = .pair_nibble_required },
        ),
    );
    const retained = try tmp.dir.readFileAlloc(
        testing.allocator,
        "no-fallback.glrt",
        1024,
    );
    defer testing.allocator.free(retained);
    try testing.expectEqualStrings(prior_destination, retained);
}

test "executable GLRT v1 admits separate policies and rejects pair-required" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const v2_path = try testTmpPath(testing.allocator, tmp.dir, "executable-v2.glrt");
    defer testing.allocator.free(v2_path);

    var model = try testPreparedModel(testing.allocator, 1);
    defer model.deinit();
    try writePrepared(
        testing.allocator,
        &model,
        v2_path,
        runtime_image.fingerprint("executable-v1-policy"),
    );
    try testRewriteSeparateV2AsV1(
        testing.allocator,
        tmp.dir,
        "executable-v2.glrt",
        "executable-v1.glrt",
    );
    const v1_path = try testTmpPath(testing.allocator, tmp.dir, "executable-v1.glrt");
    defer testing.allocator.free(v1_path);

    var automatic = try loadPrepared(testing.allocator, v1_path);
    try testing.expectEqual(
        PreparedMlpLayout.separate,
        automatic.prepared_mlp_layout.?,
    );
    automatic.deinit();

    var separate = try loadPreparedWithOptions(testing.allocator, v1_path, .{
        .mlp_layout = .separate_required,
    });
    try testing.expectEqual(
        PreparedMlpLayout.separate,
        separate.prepared_mlp_layout.?,
    );
    separate.deinit();

    try testing.expectError(
        LoaderError.PreparedMlpLayoutMismatch,
        loadPreparedWithOptions(testing.allocator, v1_path, .{
            .mlp_layout = .pair_nibble_required,
        }),
    );
}

test "prepared loader rejects pair coexistence partial branches mixed layers and geometry" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const pair_path = try testTmpPath(testing.allocator, tmp.dir, "base-pair.glrt");
    defer testing.allocator.free(pair_path);
    const separate_path = try testTmpPath(testing.allocator, tmp.dir, "base-separate.glrt");
    defer testing.allocator.free(separate_path);

    var model = try testPreparedModel(testing.allocator, 2);
    defer model.deinit();
    const fingerprint = runtime_image.fingerprint("malformed-pair-cases");
    try writePreparedWithOptions(
        testing.allocator,
        &model,
        pair_path,
        fingerprint,
        .{ .mlp_layout = .pair_nibble_required },
    );
    try writePrepared(
        testing.allocator,
        &model,
        separate_path,
        fingerprint,
    );
    var pair_image = try runtime_image.MappedImage.open(pair_path);
    defer pair_image.close();
    var separate_image = try runtime_image.MappedImage.open(separate_path);
    defer separate_image.close();

    var records: std.ArrayList(runtime_image.WriteRecord) = .{};
    defer records.deinit(testing.allocator);

    // A valid pair plus either legacy branch is ambiguous and cannot be
    // admitted, even if every individual record has a valid digest.
    for (0..pair_image.recordCount()) |index| {
        try records.append(
            testing.allocator,
            try testMappedWriteRecord(&pair_image, try pair_image.recordAt(index)),
        );
    }
    try records.append(
        testing.allocator,
        try testMappedWriteRecord(
            &separate_image,
            separate_image.find(0, .mlp_gate) orelse return error.MissingTensor,
        ),
    );
    const coexist_path = try testTmpPath(testing.allocator, tmp.dir, "coexist.glrt");
    defer testing.allocator.free(coexist_path);
    try runtime_image.writeAtomic(testing.allocator, coexist_path, .{
        .config = pair_image.header.config,
        .source_fingerprint = fingerprint,
        .sync = false,
    }, records.items);
    try testing.expectError(
        LoaderError.BadPayload,
        loadPrepared(testing.allocator, coexist_path),
    );

    // A single surviving legacy branch is not a separate representation.
    records.clearRetainingCapacity();
    for (0..separate_image.recordCount()) |index| {
        const record = try separate_image.recordAt(index);
        if (record.key.layer_idx == 0 and record.role == .tensor and
            record.key.kind == .mlp_up)
        {
            continue;
        }
        try records.append(
            testing.allocator,
            try testMappedWriteRecord(&separate_image, record),
        );
    }
    const partial_path = try testTmpPath(testing.allocator, tmp.dir, "partial.glrt");
    defer testing.allocator.free(partial_path);
    try runtime_image.writeAtomic(testing.allocator, partial_path, .{
        .config = separate_image.header.config,
        .source_fingerprint = fingerprint,
        .sync = false,
    }, records.items);
    try testing.expectError(
        LoaderError.MissingTensor,
        loadPrepared(testing.allocator, partial_path),
    );

    records.clearRetainingCapacity();
    for (0..separate_image.recordCount()) |index| {
        const record = try separate_image.recordAt(index);
        if (record.key.layer_idx == 0 and record.role == .tensor and
            (record.key.kind == .mlp_gate or record.key.kind == .mlp_up))
        {
            continue;
        }
        try records.append(
            testing.allocator,
            try testMappedWriteRecord(&separate_image, record),
        );
    }
    const absent_path = try testTmpPath(testing.allocator, tmp.dir, "absent.glrt");
    defer testing.allocator.free(absent_path);
    try runtime_image.writeAtomic(testing.allocator, absent_path, .{
        .config = separate_image.header.config,
        .source_fingerprint = fingerprint,
        .sync = false,
    }, records.items);
    try testing.expectError(
        LoaderError.MissingTensor,
        loadPrepared(testing.allocator, absent_path),
    );

    // Representation selection is model-wide, never a per-layer fallback.
    records.clearRetainingCapacity();
    for (0..pair_image.recordCount()) |index| {
        const record = try pair_image.recordAt(index);
        if (record.key.layer_idx == 1 and record.role == .mlp_gate_up_pair)
            continue;
        try records.append(
            testing.allocator,
            try testMappedWriteRecord(&pair_image, record),
        );
    }
    for ([_]fmt.TensorKind{ .mlp_gate, .mlp_up }) |kind| {
        try records.append(
            testing.allocator,
            try testMappedWriteRecord(
                &separate_image,
                separate_image.find(1, kind) orelse return error.MissingTensor,
            ),
        );
    }
    const mixed_path = try testTmpPath(testing.allocator, tmp.dir, "mixed-layers.glrt");
    defer testing.allocator.free(mixed_path);
    try runtime_image.writeAtomic(testing.allocator, mixed_path, .{
        .config = pair_image.header.config,
        .source_fingerprint = fingerprint,
        .sync = false,
    }, records.items);
    try testing.expectError(
        LoaderError.BadPayload,
        loadPrepared(testing.allocator, mixed_path),
    );

    // The record codec accepts this internally consistent 8x16 pair, but the
    // model snapshot commits hidden_dim=4. Binding must reject the mismatch.
    records.clearRetainingCapacity();
    for (0..pair_image.recordCount()) |index| {
        const record = try pair_image.recordAt(index);
        if (record.key.layer_idx == 0 and record.role == .mlp_gate_up_pair)
            continue;
        try records.append(
            testing.allocator,
            try testMappedWriteRecord(&pair_image, record),
        );
    }
    const wrong_pair_bytes = [_]u8{0xab} ** 128;
    const wrong_pair_scales = [_]f16{0.5} ** 32;
    try records.append(testing.allocator, .{
        .key = .{ .layer_idx = 0, .kind = .other },
        .role = .mlp_gate_up_pair,
        .encoding = .pair_nibble,
        .packed_layout = .none,
        .pair_nibble_layout = .rows4_k16,
        .group_size = 8,
        .out_f = 8,
        .in_f = 16,
        .num_elements = 128,
        .packed_bytes = &wrong_pair_bytes,
        .scales_f16_rows4 = std.mem.sliceAsBytes(&wrong_pair_scales),
    });
    const geometry_path = try testTmpPath(testing.allocator, tmp.dir, "geometry.glrt");
    defer testing.allocator.free(geometry_path);
    try runtime_image.writeAtomic(testing.allocator, geometry_path, .{
        .config = pair_image.header.config,
        .source_fingerprint = fingerprint,
        .sync = false,
    }, records.items);
    try testing.expectError(
        LoaderError.BadPayload,
        loadPrepared(testing.allocator, geometry_path),
    );
}

const TestPairPayload = struct {
    paired_bytes: [64]u8,
    paired_scales: [16]f16,
};

fn testPairPayload() TestPairPayload {
    var payload: TestPairPayload = undefined;
    for (&payload.paired_bytes, 0..) |*byte, index| {
        const gate: u8 = @intCast(index & 0x0f);
        const up: u8 = @intCast((index + 5) & 0x0f);
        byte.* = gate | (up << 4);
    }
    for (&payload.paired_scales, 0..) |*scale, index| {
        scale.* = @floatFromInt(index + 1);
    }
    return payload;
}

fn testPairRecord(payload: *const TestPairPayload) runtime_image.WriteRecord {
    return .{
        // The execution role, not this source-kind value, owns the artifact.
        .key = .{ .layer_idx = 0, .kind = .mlp_gate },
        .role = .mlp_gate_up_pair,
        .encoding = .pair_nibble,
        .packed_layout = .none,
        .pair_nibble_layout = .rows4_k16,
        .group_size = 8,
        .out_f = 4,
        .in_f = 16,
        .num_elements = 64,
        .packed_bytes = &payload.paired_bytes,
        .scales_f16_rows4 = std.mem.sliceAsBytes(&payload.paired_scales),
    };
}

fn testPreparedPairConfig() ModelConfig {
    return .{
        .dim = 16,
        .hidden_dim = 4,
        .num_layers = 1,
        .vocab_size = 16,
        .num_heads = 1,
        .head_dim = 16,
        .num_kv_heads = 1,
        .tie_word_embeddings = true,
    };
}

test "prepared PairNibble binds borrowed mmap slices with committed geometry" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = testPairPayload();
    const records = [_]runtime_image.WriteRecord{testPairRecord(&payload)};
    const config = testPreparedPairConfig();
    try runtime_image.writeAtomicAt(testing.allocator, tmp.dir, "pair.glrt", .{
        .config = try configSnapshot(config),
        .source_fingerprint = runtime_image.fingerprint("loader-pair-binding"),
        .sync = false,
    }, &records);

    var image = try runtime_image.MappedImage.openAt(tmp.dir, "pair.glrt");
    defer image.close();
    try testing.expectEqual(
        PreparedMlpLayout.pair_nibble,
        try validatePreparedRecordSet(&image, config),
    );
    const maybe_weights = try inspectPreparedPairNibble(&image, 0, 4, 16);
    const weights = maybe_weights orelse return error.MissingTensor;
    try int4_weights.validatePairNibble(weights);
    try testing.expectEqualSlices(u8, &payload.paired_bytes, weights.paired_bytes);
    try testing.expectEqualSlices(f16, &payload.paired_scales, weights.scales_f16_pairs);
    try testing.expectEqual(
        try int4_weights.pairNibbleGeometryCommitment(
            .gate_low_up_high_rows4_k16,
            4,
            16,
            8,
        ),
        weights.geometry_commitment,
    );
    const map_start = @intFromPtr(image.mapped.ptr);
    const map_end = map_start + image.mapped.len;
    const pair_start = @intFromPtr(weights.paired_bytes.ptr);
    const scales_start = @intFromPtr(weights.scales_f16_pairs.ptr);
    try testing.expect(pair_start >= map_start and
        pair_start + weights.paired_bytes.len <= map_end);
    try testing.expect(scales_start >= map_start and
        scales_start + std.mem.sliceAsBytes(weights.scales_f16_pairs).len <= map_end);
    try testing.expectError(
        LoaderError.BadPayload,
        inspectPreparedPairNibble(&image, 0, 8, 16),
    );
}

test "prepared schema rejects PairNibble mixed residency" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = testPairPayload();
    const packed_gate = [_]u8{0x21} ** 32;
    const gate_scales = [_]f16{0.5} ** 8;
    const records = [_]runtime_image.WriteRecord{
        testPairRecord(&payload),
        .{
            .key = .{ .layer_idx = 0, .kind = .mlp_gate },
            .encoding = .int4,
            .packed_layout = .rows4_k16,
            .group_size = 8,
            .out_f = 4,
            .in_f = 16,
            .num_elements = 64,
            .packed_bytes = &packed_gate,
            .scales_f16_rows4 = std.mem.sliceAsBytes(&gate_scales),
        },
    };
    const config = testPreparedPairConfig();
    try runtime_image.writeAtomicAt(testing.allocator, tmp.dir, "mixed.glrt", .{
        .config = try configSnapshot(config),
        .source_fingerprint = runtime_image.fingerprint("loader-mixed-pair"),
        .sync = false,
    }, &records);

    var image = try runtime_image.MappedImage.openAt(tmp.dir, "mixed.glrt");
    defer image.close();
    try testing.expectError(
        LoaderError.BadPayload,
        validatePreparedRecordSet(&image, config),
    );
}

test "prepared separate gate and up fallback remains valid without a pair role" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const packed_gate = [_]u8{0x21} ** 32;
    const packed_up = [_]u8{0x43} ** 32;
    const scales = [_]f16{0.5} ** 8;
    const records = [_]runtime_image.WriteRecord{
        .{
            .key = .{ .layer_idx = 0, .kind = .mlp_gate },
            .encoding = .int4,
            .packed_layout = .rows4_k16,
            .group_size = 8,
            .out_f = 4,
            .in_f = 16,
            .num_elements = 64,
            .packed_bytes = &packed_gate,
            .scales_f16_rows4 = std.mem.sliceAsBytes(&scales),
        },
        .{
            .key = .{ .layer_idx = 0, .kind = .mlp_up },
            .encoding = .int4,
            .packed_layout = .rows4_k16,
            .group_size = 8,
            .out_f = 4,
            .in_f = 16,
            .num_elements = 64,
            .packed_bytes = &packed_up,
            .scales_f16_rows4 = std.mem.sliceAsBytes(&scales),
        },
    };
    const config = testPreparedPairConfig();
    try runtime_image.writeAtomicAt(testing.allocator, tmp.dir, "separate.glrt", .{
        .config = try configSnapshot(config),
        .source_fingerprint = runtime_image.fingerprint("loader-separate-fallback"),
        .sync = false,
    }, &records);

    var image = try runtime_image.MappedImage.openAt(tmp.dir, "separate.glrt");
    defer image.close();
    try testing.expectEqual(
        PreparedMlpLayout.separate,
        try validatePreparedRecordSet(&image, config),
    );
    try testing.expect((try inspectPreparedPairNibble(&image, 0, 4, 16)) == null);
    const gate = try preparedInt4(&image, 0, .mlp_gate, 4, 16, false);
    const up = try preparedInt4(&image, 0, .mlp_up, 4, 16, false);
    try testing.expectEqualSlices(u8, &packed_gate, gate.packed_bytes);
    try testing.expectEqualSlices(u8, &packed_up, up.packed_bytes);
}

test "prepared load keeps CRC and descriptor digest verification independent" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = testPairPayload();
    const records = [_]runtime_image.WriteRecord{testPairRecord(&payload)};
    const config = testPreparedPairConfig();
    try runtime_image.writeAtomicAt(testing.allocator, tmp.dir, "integrity.glrt", .{
        .config = try configSnapshot(config),
        .source_fingerprint = runtime_image.fingerprint("loader-integrity"),
        .sync = false,
    }, &records);

    var image = try runtime_image.MappedImage.openAt(tmp.dir, "integrity.glrt");
    const record = image.findRole(0, .mlp_gate_up_pair) orelse
        return error.MissingTensor;
    const corrupt_offset = record.packed_bytes.offset;
    image.close();
    const file = try tmp.dir.openFile("integrity.glrt", .{ .mode = .read_write });
    defer file.close();
    _ = try file.pwrite(&[_]u8{0xff}, corrupt_offset);
    const path = try tmp.dir.realpathAlloc(testing.allocator, "integrity.glrt");
    defer testing.allocator.free(path);

    try testing.expectError(
        LoaderError.PreparedImage,
        loadPreparedWithOptions(testing.allocator, path, .{}),
    );
    try testing.expectError(
        LoaderError.PreparedImage,
        loadPreparedWithOptions(testing.allocator, path, .{
            .verify_payload_crc = false,
        }),
    );
    try testing.expectError(
        LoaderError.MissingTensor,
        loadPreparedWithOptions(testing.allocator, path, .{
            .verify_payload_crc = false,
            .verify_payload_digest = false,
        }),
    );
}
