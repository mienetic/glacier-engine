//! Perplexity computation — the decision gate for the v0.1 thesis.
//!
//! Given a sequence of token ids and a model, compute the average negative
//! log-likelihood (cross-entropy loss) the model assigns to each next-token
//! prediction. Perplexity = exp(mean NLL).
//!
//! Lower is better; a perfect model approaches perplexity 1. `compute`
//! scores every transition, while `computeLlamaCompatible` reproduces the
//! chunk-and-second-half protocol used for the head-to-head report.
//!
//! What this module does NOT do yet:
//!   - Tokenizer integration (callers pass already-tokenized ids).
//!   - Automated invocation of llama.cpp (reproduction commands live in
//!     docs/BENCHMARKS.md).

const std = @import("std");
const core = @import("core");
const forward = @import("forward.zig");
const generate = @import("generate.zig");
const loader = @import("loader.zig");

pub const Tensor = core.tensor.Tensor;

pub const PerplexityError = error{
    SequenceTooShort,
    ForwardFailed,
    OutOfMemory,
};

pub const PerplexityResult = struct {
    /// Mean negative log-likelihood (natural log), averaged over predictions.
    mean_nll: f64,
    /// Perplexity = exp(mean_nll). Lower is better.
    perplexity: f64,
    /// Number of next-token predictions evaluated (= seq_len - 1).
    num_predictions: usize,
};

const CachedNllAccumulator = struct {
    total_nll: f64 = 0,
    num_predictions: usize = 0,
    seen_in_window: usize = 0,
    skip_predictions: usize = 0,

    fn observe(context: *anyopaque, logits: []const f32, target_token: u32) void {
        const self: *CachedNllAccumulator = @ptrCast(@alignCast(context));
        defer self.seen_in_window += 1;
        if (self.seen_in_window < self.skip_predictions) return;
        var max_logit = logits[0];
        for (logits[1..]) |value| max_logit = @max(max_logit, value);
        var sum_exp: f64 = 0;
        for (logits) |value| sum_exp += std.math.exp(@as(f64, value) - max_logit);
        self.total_nll += @log(sum_exp) + max_logit - @as(f64, logits[target_token]);
        self.num_predictions += 1;
    }

    fn beginWindow(self: *CachedNllAccumulator, skip_predictions: usize) void {
        self.seen_in_window = 0;
        self.skip_predictions = skip_predictions;
    }

    fn result(self: CachedNllAccumulator) PerplexityError!PerplexityResult {
        if (self.num_predictions == 0) return PerplexityError.SequenceTooShort;
        const mean_nll = self.total_nll / @as(f64, @floatFromInt(self.num_predictions));
        return .{
            .mean_nll = mean_nll,
            .perplexity = @exp(mean_nll),
            .num_predictions = self.num_predictions,
        };
    }
};

fn scoreCachedWindow(
    allocator: std.mem.Allocator,
    model: loader.LoadedModel,
    tokens: []const u32,
    skip_predictions: usize,
    accumulator: *CachedNllAccumulator,
) PerplexityError!void {
    if (tokens.len < 2) return PerplexityError.SequenceTooShort;
    accumulator.beginWindow(skip_predictions);
    const generated = generate.generate(allocator, model, tokens[0..1], .{
        .max_new_tokens = tokens.len - 1,
        .forced_tokens = tokens[1..],
        .logits_observer = .{
            .context = accumulator,
            .observe = CachedNllAccumulator.observe,
        },
    }) catch |err| switch (err) {
        error.OutOfMemory => return PerplexityError.OutOfMemory,
        else => return PerplexityError.ForwardFailed,
    };
    allocator.free(generated);
}

/// Score the production cached decode graph with teacher-forced tokens.
/// Unlike `compute`, this exercises packed INT4 weights and Q8 activations.
pub fn computeCached(
    allocator: std.mem.Allocator,
    model: loader.LoadedModel,
    token_ids: []const u32,
    batch_len: usize,
) PerplexityError!PerplexityResult {
    if (token_ids.len < 2 or batch_len < 2) return PerplexityError.SequenceTooShort;
    var accumulator: CachedNllAccumulator = .{};
    var start: usize = 0;
    while (start + 1 < token_ids.len) {
        const end = @min(start + batch_len, token_ids.len);
        try scoreCachedWindow(allocator, model, token_ids[start..end], 0, &accumulator);
        if (end == token_ids.len) break;
        start = end - 1;
    }
    return accumulator.result();
}

/// Cached-Q8 counterpart of `computeLlamaCompatible`: full fixed chunks,
/// scoring only predictions made from positions in the second half.
pub fn computeCachedLlamaCompatible(
    allocator: std.mem.Allocator,
    model: loader.LoadedModel,
    token_ids: []const u32,
    context_len: usize,
) PerplexityError!PerplexityResult {
    if (context_len < 2 or token_ids.len / context_len < 2)
        return PerplexityError.SequenceTooShort;
    var accumulator: CachedNllAccumulator = .{};
    const chunk_count = token_ids.len / context_len;
    const first = context_len / 2;
    for (0..chunk_count) |chunk_idx| {
        const start = chunk_idx * context_len;
        try scoreCachedWindow(
            allocator,
            model,
            token_ids[start .. start + context_len],
            first,
            &accumulator,
        );
    }
    return accumulator.result();
}

/// Compute perplexity over a token sequence.
///
/// `token_ids` : the full eval sequence. We predict token[i+1] from
///               token[0..=i], so num_predictions = token_ids.len - 1.
/// `batch_len` : maximum context window evaluated at once. Windows overlap
///               by one token so every transition is scored exactly once.
///               Larger values preserve more context but use more memory.
pub fn compute(
    allocator: std.mem.Allocator,
    model: loader.LoadedModel,
    token_ids: []const u32,
    batch_len: usize,
) PerplexityError!PerplexityResult {
    if (token_ids.len < 2) return PerplexityError.SequenceTooShort;
    if (batch_len < 2) return PerplexityError.SequenceTooShort;

    var total_nll: f64 = 0;
    var num_predictions: usize = 0;
    const vocab = model.config.vocab_size;

    // Score every next-token transition in bounded windows. Adjacent windows
    // overlap by one token: the final token in one window becomes the first
    // context token in the next. This avoids dropping boundary predictions
    // while keeping the peak logits allocation bounded by `batch_len`.
    var start: usize = 0;
    while (start + 1 < token_ids.len) {
        const end = @min(start + batch_len, token_ids.len);
        const window_len = end - start;
        if (window_len < 2) break;

        const window = token_ids[start..end];
        var logits = try core.tensor.zerosF32(allocator, &.{ window_len, vocab });
        defer logits.deinit();

        forward.forwardModel(allocator, model, window, logits) catch
            return PerplexityError.ForwardFailed;

        var pos: usize = 0;
        while (pos + 1 < window_len) : (pos += 1) {
            const target = token_ids[start + pos + 1];
            if (target >= vocab) return PerplexityError.ForwardFailed;
            const row_start = pos * vocab;
            const logits_row = logits.asF32()[row_start .. row_start + vocab];

            // Stable log-softmax: NLL = logsumexp(logits) - target_logit.
            var max_logit: f32 = logits_row[0];
            for (logits_row[1..]) |v| if (v > max_logit) {
                max_logit = v;
            };
            var sum_exp: f64 = 0;
            for (logits_row) |v| sum_exp += std.math.exp(@as(f64, v) - max_logit);
            const log_sum_exp = @log(sum_exp) + max_logit;
            total_nll += log_sum_exp - @as(f64, logits_row[target]);
            num_predictions += 1;
        }

        if (end == token_ids.len) break;
        start = end - 1;
    }

    if (num_predictions == 0) return PerplexityError.SequenceTooShort;
    const mean_nll = total_nll / @as(f64, @floatFromInt(num_predictions));
    return .{
        .mean_nll = mean_nll,
        .perplexity = @exp(mean_nll),
        .num_predictions = num_predictions,
    };
}

/// Match llama.cpp's default perplexity protocol for head-to-head reports:
/// split the corpus into non-overlapping, full `context_len` chunks and score
/// only the final half of each chunk. The first half supplies context; a
/// trailing partial chunk is ignored. At least two full chunks are required,
/// mirroring llama-perplexity's minimum-corpus gate.
pub fn computeLlamaCompatible(
    allocator: std.mem.Allocator,
    model: loader.LoadedModel,
    token_ids: []const u32,
    context_len: usize,
) PerplexityError!PerplexityResult {
    if (context_len < 2 or token_ids.len / context_len < 2) return PerplexityError.SequenceTooShort;
    const vocab = model.config.vocab_size;
    const chunk_count = token_ids.len / context_len;
    const first = context_len / 2;
    var total_nll: f64 = 0;
    var num_predictions: usize = 0;

    for (0..chunk_count) |chunk_idx| {
        const start = chunk_idx * context_len;
        const window = token_ids[start .. start + context_len];
        var logits = try core.tensor.zerosF32(allocator, &.{ context_len, vocab });
        defer logits.deinit();
        forward.forwardModel(allocator, model, window, logits) catch
            return PerplexityError.ForwardFailed;

        var pos = first;
        while (pos + 1 < context_len) : (pos += 1) {
            const target = window[pos + 1];
            if (target >= vocab) return PerplexityError.ForwardFailed;
            const row_start = pos * vocab;
            const logits_row = logits.asF32()[row_start .. row_start + vocab];
            var max_logit = logits_row[0];
            for (logits_row[1..]) |value| if (value > max_logit) {
                max_logit = value;
            };
            var sum_exp: f64 = 0;
            for (logits_row) |value| sum_exp += std.math.exp(@as(f64, value) - max_logit);
            total_nll += @log(sum_exp) + max_logit - @as(f64, logits_row[target]);
            num_predictions += 1;
        }
    }

    const mean_nll = total_nll / @as(f64, @floatFromInt(num_predictions));
    return .{
        .mean_nll = mean_nll,
        .perplexity = @exp(mean_nll),
        .num_predictions = num_predictions,
    };
}
