//! Same-process real-weight A/B for exact eligible-vocabulary argmax.
//!
//! This intentionally benchmarks only the isolated LM-head API. The model
//! weights come from a production GLRT image, while the activation is a
//! deterministic synthetic finite vector so the artifact must not be cited as
//! an end-to-end decode result. Model loading, hashing, and mask construction
//! are excluded from every timed sample.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");
const tensor = engine.core.tensor;
const int4_executor = engine.int4_executor;

const schema = "glacier.eligible-argmax-kernel/raw-v2";

pub fn main() !void {
    if (builtin.cpu.arch != .aarch64) return error.AArch64Required;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 6) return error.InvalidUsage;

    const model_path = args[1];
    const samples = try std.fmt.parseInt(usize, args[2], 10);
    const warmups = try std.fmt.parseInt(usize, args[3], 10);
    const threads = try std.fmt.parseInt(usize, args[4], 10);
    const requested_eligible = try std.fmt.parseInt(usize, args[5], 10);
    if (samples < 2 or samples > 100_000 or warmups > 10_000 or
        threads == 0 or threads > 256 or requested_eligible == 0)
        return error.InvalidUsage;

    var model = try engine.loader.loadPrepared(allocator, model_path);
    defer model.deinit();
    const weights = model.lm_head_int4 orelse return error.MissingLmHead;
    const out_f = model.config.vocab_size;
    const in_f = model.config.dim;
    if (out_f == 0 or out_f % 4 != 0 or in_f == 0 or
        requested_eligible > out_f or weights.packed_layout != .rows4_k16)
        return error.UnsupportedModel;

    const input_values = try allocator.alloc(f32, in_f);
    defer allocator.free(input_values);
    for (input_values, 0..) |*value, index| {
        const signed: i32 = @intCast((index * 73 + 19) % 509);
        value.* = @as(f32, @floatFromInt(signed - 254)) / 127.0;
    }
    var input = try tensor.fromF32(allocator, &.{ 1, in_f }, input_values);
    defer input.deinit();

    var executor: int4_executor.Executor = undefined;
    try executor.initWithOptions(
        allocator,
        threads,
        .{ .greedy_argmax = true },
    );
    defer executor.deinit();

    // Establish an independent materialized rows4 oracle before constructing
    // the eligible set. This allocation/projection/scan is outside every
    // timed region and catches reduction-only bugs shared by the two APIs.
    var materialized = try tensor.zerosF32(allocator, &.{ 1, out_f });
    defer materialized.deinit();
    const materialized_projection: int4_executor.Projection = .{
        .x = input,
        .weights = weights,
        .bias = &.{},
        .out = materialized,
        .out_f = out_f,
        .in_f = in_f,
        .use_q8 = true,
    };
    try executor.run(&.{materialized_projection});
    const materialized_oracle = try materializedWinner(
        materialized.asF32(),
        null,
    );
    const full_winner = try executor.runGreedyArgmax(
        input,
        weights,
        out_f,
        in_f,
    );
    if (full_winner != materialized_oracle) return error.OracleMismatch;

    const word_count = out_f / 64 + @intFromBool(out_f % 64 != 0);
    const eligible_words = try allocator.alloc(u64, word_count);
    defer allocator.free(eligible_words);
    @memset(eligible_words, 0);
    setEligible(eligible_words, materialized_oracle);
    var eligible_count: usize = 1;
    var step: usize = 104_729 % out_f;
    if (step == 0) step = 1;
    while (greatestCommonDivisor(step, out_f) != 1) {
        step += 1;
        if (step == out_f) step = 1;
    }
    var candidate: usize = 17 % out_f;
    while (eligible_count < requested_eligible) {
        if (!isEligible(eligible_words, candidate)) {
            setEligible(eligible_words, candidate);
            eligible_count += 1;
        }
        candidate = if (candidate >= out_f - step)
            candidate - (out_f - step)
        else
            candidate + step;
    }
    const eligible_materialized_oracle = try materializedWinner(
        materialized.asF32(),
        eligible_words,
    );

    var mask_hash = std.crypto.hash.sha2.Sha256.init(.{});
    mask_hash.update(std.mem.sliceAsBytes(eligible_words));
    var mask_digest: [32]u8 = undefined;
    mask_hash.final(&mask_digest);

    var reference = try executor.runGreedyArgmaxEligible(
        input,
        weights,
        out_f,
        in_f,
        eligible_words,
    );
    try validateEligibleResult(
        reference,
        eligible_materialized_oracle,
        out_f,
        requested_eligible,
    );

    // Warm both variants symmetrically. Alternating order avoids assigning all
    // first-use or thermal drift to one side.
    for (0..warmups) |round| {
        if (round % 2 == 0) {
            try expectFull(
                &executor,
                input,
                weights,
                out_f,
                in_f,
                materialized_oracle,
            );
            reference = try expectEligible(
                &executor,
                input,
                weights,
                out_f,
                in_f,
                eligible_words,
                eligible_materialized_oracle,
                reference,
            );
        } else {
            reference = try expectEligible(
                &executor,
                input,
                weights,
                out_f,
                in_f,
                eligible_words,
                eligible_materialized_oracle,
                reference,
            );
            try expectFull(
                &executor,
                input,
                weights,
                out_f,
                in_f,
                materialized_oracle,
            );
        }
    }

    const full_ns = try allocator.alloc(u64, samples);
    defer allocator.free(full_ns);
    const eligible_ns = try allocator.alloc(u64, samples);
    defer allocator.free(eligible_ns);
    var checksum: usize = 0;
    for (0..samples) |round| {
        if (round % 2 == 0) {
            full_ns[round] = try timeFull(
                &executor,
                input,
                weights,
                out_f,
                in_f,
                materialized_oracle,
                &checksum,
            );
            const timed = try timeEligible(
                &executor,
                input,
                weights,
                out_f,
                in_f,
                eligible_words,
                eligible_materialized_oracle,
                reference,
                &checksum,
            );
            eligible_ns[round] = timed.ns;
            reference = timed.result;
        } else {
            const timed = try timeEligible(
                &executor,
                input,
                weights,
                out_f,
                in_f,
                eligible_words,
                eligible_materialized_oracle,
                reference,
                &checksum,
            );
            eligible_ns[round] = timed.ns;
            reference = timed.result;
            full_ns[round] = try timeFull(
                &executor,
                input,
                weights,
                out_f,
                in_f,
                materialized_oracle,
                &checksum,
            );
        }
    }

    const stdout = std.fs.File.stdout();
    var output_buffer: [64 * 1024]u8 = undefined;
    var output_writer = std.fs.File.Writer.init(stdout, &output_buffer);
    const writer = &output_writer.interface;
    defer writer.flush() catch {};
    try writer.print(
        "eligible_argmax: schema={s} vocab={d} dim={d} group_size={d} threads={d} samples={d} warmups={d} materialized_oracle={d} full_winner={d} eligible_materialized_oracle={d} eligible_winner={d} eligible_rows={d} producer_rows={d} skipped_rows={d} overcomputed_rows={d} producer_runs={d} tile_scratch_bytes={d} executor_scratch_bytes={d} greedy_abi={x} eligibility_abi={x} optimize={s} metal_enabled={d} zig={s} checksum={d}\n",
        .{
            schema,
            out_f,
            in_f,
            weights.group_size,
            threads,
            samples,
            warmups,
            materialized_oracle,
            full_winner,
            eligible_materialized_oracle,
            reference.token_index,
            reference.eligible_rows,
            reference.producer_rows,
            reference.skipped_rows,
            reference.overcomputed_rows,
            reference.producer_runs,
            reference.tile_scratch_bytes,
            executor.greedyArgmaxScratchBytes(),
            int4_executor.greedy_argmax_abi,
            int4_executor.greedy_eligibility_abi,
            @tagName(builtin.mode),
            @intFromBool(engine.metal_enabled),
            builtin.zig_version_string,
            checksum,
        },
    );
    try writer.writeAll("mask_sha256: ");
    for (mask_digest) |byte| try writer.print("{x:0>2}", .{byte});
    try writer.writeByte('\n');
    try writeEligibleIds(writer, eligible_words, out_f);
    try writeSamples(writer, "full_ns", full_ns);
    try writeSamples(writer, "eligible_ns", eligible_ns);
    try writer.writeAll("schedule: F,E,E,F repeated-by-round\n");
    try writer.writeAll(
        "scope: real_glrt_weights deterministic_synthetic_f32_input isolated_lm_head excludes_load_and_decode\n",
    );
}

fn greatestCommonDivisor(left: usize, right: usize) usize {
    var a = left;
    var b = right;
    while (b != 0) {
        const next = a % b;
        a = b;
        b = next;
    }
    return a;
}

fn setEligible(words: []u64, token: usize) void {
    words[token / 64] |= @as(u64, 1) << @as(u6, @intCast(token % 64));
}

fn materializedWinner(
    values: []const f32,
    eligible_words: ?[]const u64,
) !usize {
    var winner: usize = 0;
    var winner_value: f32 = -std.math.inf(f32);
    var found = false;
    for (values, 0..) |value, token| {
        if (eligible_words) |words| {
            if (!isEligible(words, token)) continue;
        }
        if (std.math.isNan(value)) return error.OracleNaN;
        if (!found or value > winner_value or
            (value == winner_value and token < winner))
        {
            winner = token;
            winner_value = value;
            found = true;
        }
    }
    if (!found) return error.EmptyOracle;
    return winner;
}

fn isEligible(words: []const u64, token: usize) bool {
    return words[token / 64] &
        (@as(u64, 1) << @as(u6, @intCast(token % 64))) != 0;
}

fn validateEligibleResult(
    result: int4_executor.EligibleGreedyResult,
    oracle: usize,
    out_f: usize,
    eligible_rows: usize,
) !void {
    if (result.token_index != oracle or result.eligible_rows != eligible_rows or
        result.producer_rows < result.eligible_rows or
        result.producer_rows + result.skipped_rows != out_f or
        result.producer_rows - result.eligible_rows != result.overcomputed_rows or
        result.producer_runs < result.producer_rows / 64 +
            @intFromBool(result.producer_rows % 64 != 0) or
        result.producer_runs > result.producer_rows / 4 or
        result.tile_scratch_bytes == 0)
        return error.ResultMismatch;
}

fn sameCounters(
    left: int4_executor.EligibleGreedyResult,
    right: int4_executor.EligibleGreedyResult,
) bool {
    return left.token_index == right.token_index and
        left.eligible_rows == right.eligible_rows and
        left.producer_rows == right.producer_rows and
        left.skipped_rows == right.skipped_rows and
        left.overcomputed_rows == right.overcomputed_rows and
        left.producer_runs == right.producer_runs and
        left.tile_scratch_bytes == right.tile_scratch_bytes;
}

fn expectFull(
    executor: *int4_executor.Executor,
    input: tensor.Tensor,
    weights: engine.int4_weights.Int4WeightData,
    out_f: usize,
    in_f: usize,
    oracle: usize,
) !void {
    if (try executor.runGreedyArgmax(input, weights, out_f, in_f) != oracle)
        return error.ResultMismatch;
}

fn expectEligible(
    executor: *int4_executor.Executor,
    input: tensor.Tensor,
    weights: engine.int4_weights.Int4WeightData,
    out_f: usize,
    in_f: usize,
    eligible_words: []const u64,
    oracle: usize,
    reference: int4_executor.EligibleGreedyResult,
) !int4_executor.EligibleGreedyResult {
    const result = try executor.runGreedyArgmaxEligible(
        input,
        weights,
        out_f,
        in_f,
        eligible_words,
    );
    try validateEligibleResult(result, oracle, out_f, reference.eligible_rows);
    if (!sameCounters(result, reference)) return error.CounterMismatch;
    return result;
}

fn timeFull(
    executor: *int4_executor.Executor,
    input: tensor.Tensor,
    weights: engine.int4_weights.Int4WeightData,
    out_f: usize,
    in_f: usize,
    oracle: usize,
    checksum: *usize,
) !u64 {
    var timer = try std.time.Timer.start();
    const winner = try executor.runGreedyArgmax(input, weights, out_f, in_f);
    const elapsed = timer.read();
    if (winner != oracle) return error.ResultMismatch;
    checksum.* +%= winner;
    return elapsed;
}

const TimedEligible = struct {
    ns: u64,
    result: int4_executor.EligibleGreedyResult,
};

fn timeEligible(
    executor: *int4_executor.Executor,
    input: tensor.Tensor,
    weights: engine.int4_weights.Int4WeightData,
    out_f: usize,
    in_f: usize,
    eligible_words: []const u64,
    oracle: usize,
    reference: int4_executor.EligibleGreedyResult,
    checksum: *usize,
) !TimedEligible {
    var timer = try std.time.Timer.start();
    const result = try executor.runGreedyArgmaxEligible(
        input,
        weights,
        out_f,
        in_f,
        eligible_words,
    );
    const elapsed = timer.read();
    try validateEligibleResult(result, oracle, out_f, reference.eligible_rows);
    if (!sameCounters(result, reference)) return error.CounterMismatch;
    checksum.* +%= result.token_index;
    return .{ .ns = elapsed, .result = result };
}

fn writeSamples(writer: *std.Io.Writer, label: []const u8, values: []const u64) !void {
    try writer.print("{s}: ", .{label});
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{value});
    }
    try writer.writeByte('\n');
}

fn writeEligibleIds(
    writer: *std.Io.Writer,
    eligible_words: []const u64,
    out_f: usize,
) !void {
    try writer.writeAll("eligible_ids: ");
    var first = true;
    for (0..out_f) |token| {
        if (!isEligible(eligible_words, token)) continue;
        if (!first) try writer.writeByte(',');
        try writer.print("{d}", .{token});
        first = false;
    }
    try writer.writeByte('\n');
}
