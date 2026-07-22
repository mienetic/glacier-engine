//! Token sampling for generation.
//!
//! Replaces the greedy argmax decode with the standard LLM sampling stack:
//!   1. Temperature scaling: logits /= temp (temp > 1 flattens, < 1 sharpens).
//!   2. Top-k filtering: keep only the k highest-probability tokens.
//!   3. Top-p (nucleus) filtering: keep the smallest set whose cumulative
//!      probability ≥ p.
//!   4. Sample from the renormalized softmax distribution.
//!
//! All randomness goes through a caller-provided Random so generation is
//! reproducible from a seed — important for benchmarking and for the
//! engine's claim that numbers are deterministic.

const std = @import("std");
const builtin = @import("builtin");

extern fn glacier_argmax_f32_neon(values: [*]const f32, count: usize) usize;

pub const SamplerConfig = struct {
    /// 1.0 = unchanged. <1 sharpens (more deterministic), >1 flattens
    /// (more random). 0 is treated as greedy.
    temperature: f32 = 1.0,
    /// 0 = disabled. Otherwise keep only the top-k logits.
    top_k: usize = 0,
    /// 1.0 = disabled. Otherwise keep the smallest set whose cumulative
    /// probability ≥ top_p (nucleus sampling).
    top_p: f32 = 1.0,
};

/// One entry in the candidate set after filtering. Indices refer back to
/// the original logits slice so the caller can map back to token ids.
pub const Candidate = struct {
    idx: usize,
    logit: f32,
};

/// Failure modes for a caller-provided eligible-vocabulary bitset.
pub const EligibleArgmaxError = error{
    InvalidEligibleMask,
    EligibleLogitNaN,
};

/// Canonical greedy result over exactly the caller-provided eligible rows.
pub const EligibleArgmaxResult = struct {
    token_index: usize,
    eligible_rows: usize,
};

/// Return the canonical greedy winner among the set bits in `eligible_words`.
///
/// The bitset must contain exactly `ceil(logits.len / 64)` words, contain at
/// least one set bit, and keep every bit beyond `logits.len` clear. Logits for
/// clear bits are never read. NaN is rejected only when its row is eligible;
/// infinities are valid scores. Equal scores resolve to the lowest token ID.
pub fn argmaxEligible(
    logits: []const f32,
    eligible_words: []const u64,
) EligibleArgmaxError!EligibleArgmaxResult {
    const word_count = logits.len / 64 + @intFromBool(logits.len % 64 != 0);
    if (word_count == 0 or eligible_words.len != word_count)
        return EligibleArgmaxError.InvalidEligibleMask;

    if (logits.len % 64 != 0) {
        const tail_bits: u6 = @intCast(logits.len % 64);
        const valid_tail = (@as(u64, 1) << tail_bits) - 1;
        if (eligible_words[word_count - 1] & ~valid_tail != 0)
            return EligibleArgmaxError.InvalidEligibleMask;
    }

    var eligible_rows: usize = 0;
    for (eligible_words) |word| {
        eligible_rows = std.math.add(
            usize,
            eligible_rows,
            @popCount(word),
        ) catch return EligibleArgmaxError.InvalidEligibleMask;
    }
    if (eligible_rows == 0 or eligible_rows > logits.len)
        return EligibleArgmaxError.InvalidEligibleMask;

    var best_index: usize = 0;
    var best_value: f32 = undefined;
    var have_best = false;
    for (eligible_words, 0..) |eligible_word, word_index| {
        var remaining = eligible_word;
        while (remaining != 0) {
            const bit: u6 = @intCast(@ctz(remaining));
            const token_index = word_index * 64 + @as(usize, bit);
            const value = logits[token_index];
            if (std.math.isNan(value))
                return EligibleArgmaxError.EligibleLogitNaN;
            if (!have_best or value > best_value) {
                best_index = token_index;
                best_value = value;
                have_best = true;
            }
            remaining &= remaining - 1;
        }
    }
    std.debug.assert(have_best);
    return .{
        .token_index = best_index,
        .eligible_rows = eligible_rows,
    };
}

/// Apply temperature, top-k, top-p, then sample one token index from the
/// resulting distribution. Returns the sampled index into `logits`.
///
/// `scratch` is caller-provided temp storage for the candidate list; we
/// avoid allocating inside the sampler so the hot decode loop stays
/// allocator-free.
pub fn sample(
    logits: []const f32,
    cfg: SamplerConfig,
    rng: std.Random,
    scratch_candidates: []Candidate,
) usize {
    if (cfg.temperature == 0) {
        // Greedy: pure argmax.
        return argmax(logits);
    }

    // Step 1: temperature + copy into candidate list.
    const inv_temp = 1.0 / cfg.temperature;
    var n: usize = 0;
    for (logits, 0..) |l, i| {
        if (n >= scratch_candidates.len) break;
        scratch_candidates[n] = .{ .idx = i, .logit = l * inv_temp };
        n += 1;
    }
    var cands = scratch_candidates[0..n];

    // Step 2: top-k. Sort descending and truncate. We only sort when
    // top_k is set AND smaller than the candidate count.
    if (cfg.top_k > 0 and cfg.top_k < cands.len) {
        std.sort.heap(Candidate, cands, {}, struct {
            fn lt(_: void, a: Candidate, b: Candidate) bool {
                return a.logit > b.logit;
            }
        }.lt);
        cands = cands[0..cfg.top_k];
    }

    // Compute softmax over the (possibly filtered) candidates.
    var max_logit: f32 = cands[0].logit;
    for (cands[1..]) |c| if (c.logit > max_logit) {
        max_logit = c.logit;
    };
    var sum_exp: f32 = 0;
    for (cands) |*c| {
        c.logit = std.math.exp(c.logit - max_logit);
        sum_exp += c.logit;
    }
    // Normalize to probabilities.
    for (cands) |*c| c.logit /= sum_exp;

    // Step 3: top-p (nucleus). Sort descending by probability (already
    // sorted if top-k ran; otherwise sort now) and keep the smallest
    // prefix whose cumulative prob ≥ top_p.
    if (cfg.top_p < 1.0) {
        std.sort.heap(Candidate, cands, {}, struct {
            fn lt(_: void, a: Candidate, b: Candidate) bool {
                return a.logit > b.logit;
            }
        }.lt);
        var cum: f32 = 0;
        var keep: usize = cands.len;
        for (cands, 0..) |c, i| {
            cum += c.logit;
            if (cum >= cfg.top_p) {
                keep = i + 1;
                break;
            }
        }
        cands = cands[0..keep];
        // Renormalize.
        sum_exp = 0;
        for (cands) |c| sum_exp += c.logit;
        for (cands) |*c| c.logit /= sum_exp;
    }

    // Step 4: sample from the renormalized distribution.
    const r = rng.float(f32);
    var cum: f32 = 0;
    for (cands) |c| {
        cum += c.logit;
        if (r <= cum) return c.idx;
    }
    // Floating-point fallback: return the last candidate.
    return cands[cands.len - 1].idx;
}

fn argmax(v: []const f32) usize {
    if (comptime builtin.cpu.arch == .aarch64)
        return glacier_argmax_f32_neon(v.ptr, v.len);
    var best_i: usize = 0;
    var best_v: f32 = v[0];
    for (v[1..], 1..) |x, i| {
        if (x > best_v) {
            best_v = x;
            best_i = i;
        }
    }
    return best_i;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "temperature 0 falls back to greedy argmax" {
    const logits = [_]f32{ 1, 5, 2, 4 };
    var rng_prng = std.Random.DefaultPrng.init(0);
    const rng = rng_prng.random();
    var scratch: [4]Candidate = undefined;
    const picked = sample(&logits, .{ .temperature = 0 }, rng, &scratch);
    try testing.expectEqual(@as(usize, 1), picked); // index of value 5
}

test "eligible argmax validates exact mask geometry and nonempty domain" {
    const logits = [_]f32{0} ** 65;

    try testing.expectError(
        EligibleArgmaxError.InvalidEligibleMask,
        argmaxEligible(&logits, &.{}),
    );
    try testing.expectError(
        EligibleArgmaxError.InvalidEligibleMask,
        argmaxEligible(&logits, &.{1}),
    );
    try testing.expectError(
        EligibleArgmaxError.InvalidEligibleMask,
        argmaxEligible(&logits, &.{ 1, 0, 0 }),
    );
    try testing.expectError(
        EligibleArgmaxError.InvalidEligibleMask,
        argmaxEligible(&logits, &.{ 0, 0 }),
    );
    try testing.expectError(
        EligibleArgmaxError.InvalidEligibleMask,
        argmaxEligible(&logits, &.{ 1, 0b10 }),
    );
    try testing.expectError(
        EligibleArgmaxError.InvalidEligibleMask,
        argmaxEligible(&.{}, &.{}),
    );
}

test "eligible argmax scans set bits only and reports their count" {
    var logits = [_]f32{-100} ** 130;
    logits[0] = std.math.nan(f32);
    logits[5] = 3.0;
    logits[67] = 9.0;
    logits[129] = 8.0;
    const result = try argmaxEligible(
        &logits,
        &.{ @as(u64, 1) << 5, @as(u64, 1) << 3, @as(u64, 1) << 1 },
    );
    try testing.expectEqual(@as(usize, 67), result.token_index);
    try testing.expectEqual(@as(usize, 3), result.eligible_rows);
}

test "eligible argmax rejects eligible NaN" {
    const logits = [_]f32{ 10.0, std.math.nan(f32), 20.0 };
    try testing.expectError(
        EligibleArgmaxError.EligibleLogitNaN,
        argmaxEligible(&logits, &.{0b110}),
    );
}

test "eligible argmax accepts infinities and breaks ties by lowest token ID" {
    const positive = [_]f32{ 0.0, std.math.inf(f32), 7.0, std.math.inf(f32) };
    const positive_result = try argmaxEligible(&positive, &.{0b1010});
    try testing.expectEqual(@as(usize, 1), positive_result.token_index);

    const negative = [_]f32{ 0.0, -std.math.inf(f32), 7.0, -std.math.inf(f32) };
    const negative_result = try argmaxEligible(&negative, &.{0b1010});
    try testing.expectEqual(@as(usize, 1), negative_result.token_index);

    const finite = [_]f32{ 5.0, 0.0, 5.0, 0.0 };
    const finite_result = try argmaxEligible(&finite, &.{0b0101});
    try testing.expectEqual(@as(usize, 0), finite_result.token_index);
}

test "high temperature spreads probability across more tokens" {
    // With temp → ∞ the distribution approaches uniform. We can't assert
    // a specific draw, but we CAN assert that across many samples the
    // greedy argmax is NOT picked every time.
    const logits = [_]f32{ 10, 0, 0, 0 }; // strongly peaked at index 0
    var rng_prng = std.Random.DefaultPrng.init(1);
    const rng = rng_prng.random();
    var scratch: [4]Candidate = undefined;

    var non_argmax: usize = 0;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const picked = sample(&logits, .{ .temperature = 100 }, rng, &scratch);
        if (picked != 0) non_argmax += 1;
    }
    // At temp=100 with this peak, we expect many non-zero draws.
    try testing.expect(non_argmax > 50);
}

test "top-k restricts to the k highest logits" {
    // top-k=2 with logits [1,5,2,4] → only indices 1 and 4 are eligible.
    // Sample many times; the picked index must always be in {1, 3}.
    const logits = [_]f32{ 1, 5, 2, 4 };
    var rng_prng = std.Random.DefaultPrng.init(2);
    const rng = rng_prng.random();
    var scratch: [4]Candidate = undefined;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const picked = sample(&logits, .{ .temperature = 1.0, .top_k = 2 }, rng, &scratch);
        try testing.expect(picked == 1 or picked == 3);
    }
}

test "deterministic with the same seed" {
    const logits = [_]f32{ 1, 5, 2, 4, 3, 0, 7, 2 };
    var scratch: [8]Candidate = undefined;

    var rng1_prng = std.Random.DefaultPrng.init(42);
    var rng2_prng = std.Random.DefaultPrng.init(42);
    const rng1 = rng1_prng.random();
    const rng2 = rng2_prng.random();
    const cfg = SamplerConfig{ .temperature = 1.0, .top_k = 4, .top_p = 0.9 };
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const a = sample(&logits, cfg, rng1, &scratch);
        const b = sample(&logits, cfg, rng2, &scratch);
        try testing.expectEqual(a, b);
    }
}

test "top-p=1.0 disables nucleus filtering" {
    // Should behave like pure temperature sampling — every token eligible.
    const logits = [_]f32{ 1, 5, 2, 4 };
    var rng_prng = std.Random.DefaultPrng.init(3);
    const rng = rng_prng.random();
    var scratch: [4]Candidate = undefined;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const picked = sample(&logits, .{ .temperature = 1.0, .top_p = 1.0 }, rng, &scratch);
        try testing.expect(picked < 4);
    }
}
