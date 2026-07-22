//! Same-process actual-model smoke driver for grounded DecodeLane4 observations.
//!
//! This executable loads one immutable PairNibble GLRT image once, constructs
//! four deterministic equal-length requests, and runs one M1x4/B4 pair with
//! exactly four inference participants per arm. It refuses to print a result
//! unless the observation layer proves exact cross-arm token/KV/RNG/output
//! state equivalence.
//!
//! The output is deliberately labelled non-publishable. One thread-cold pair
//! has no balanced ABBA/BAAB schedule, external physical sampler, power/thermal
//! bracketing, confidence interval, or current-pin cross-engine quality gate.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");
const observation = @import("lane4_runner_observation");
const runner_core = @import("lane4_runner_core");

const schema = "glacier.decode-lane4/actual-model-smoke-v6";
const width = observation.width;
const new_tokens = observation.tokens_per_lane;

fn parseGreedyHeadMode(value: []const u8) !engine.decode_lane4.GreedyHeadMode {
    if (std.mem.eql(u8, value, "materialized")) return .materialized;
    if (std.mem.eql(u8, value, "streaming-required"))
        return .streaming_required;
    return error.InvalidUsage;
}

fn greedyHeadModeLabel(mode: engine.decode_lane4.GreedyHeadMode) []const u8 {
    return switch (mode) {
        .materialized => "materialized",
        .streaming_required => "streaming-required",
    };
}

fn parseAttentionMode(value: []const u8) !engine.decode_lane4.AttentionMode {
    if (std.mem.eql(u8, value, "serial")) return .serial;
    if (std.mem.eql(u8, value, "shared-kv-required"))
        return .shared_kv_required;
    return error.InvalidUsage;
}

fn attentionModeLabel(mode: engine.decode_lane4.AttentionMode) []const u8 {
    return switch (mode) {
        .serial => "serial",
        .shared_kv_required => "shared-kv-required",
    };
}

fn parsePairDownMode(value: []const u8) !engine.decode_lane4.PairDownMode {
    if (std.mem.eql(u8, value, "split-control")) return .split_control;
    if (std.mem.eql(u8, value, "single-epoch-required"))
        return .single_epoch_required;
    return error.InvalidUsage;
}

fn pairDownModeLabel(mode: engine.decode_lane4.PairDownMode) []const u8 {
    return switch (mode) {
        .split_control => "split-control",
        .single_epoch_required => "single-epoch-required",
    };
}

const ArmOrder = enum {
    m1x4_b4,
    b4_m1x4,

    fn parse(value: []const u8) !ArmOrder {
        if (std.mem.eql(u8, value, "m1x4-b4")) return .m1x4_b4;
        if (std.mem.eql(u8, value, "b4-m1x4")) return .b4_m1x4;
        return error.InvalidUsage;
    }

    fn label(self: ArmOrder) []const u8 {
        return switch (self) {
            .m1x4_b4 => "m1x4-b4",
            .b4_m1x4 => "b4-m1x4",
        };
    }
};

const FileIdentity = struct {
    sha256: [32]u8,
    stat: std.fs.File.Stat,
};

fn hashFile(path: []const u8) !FileIdentity {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    if (stat.size == 0) return error.InvalidArtifact;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < stat.size) {
        const wanted: usize = @intCast(@min(stat.size - offset, buffer.len));
        const bytes_read = try file.pread(buffer[0..wanted], offset);
        if (bytes_read == 0) return error.UnexpectedEndOfFile;
        hash.update(buffer[0..bytes_read]);
        offset += bytes_read;
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return .{ .sha256 = digest, .stat = stat };
}

fn requireUnchanged(path: []const u8, before: std.fs.File.Stat) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const after = try file.stat();
    if (before.inode != after.inode or before.size != after.size or
        before.mtime != after.mtime or before.ctime != after.ctime)
        return error.ArtifactChangedDuringObservation;
}

fn readBaseTokens(
    allocator: std.mem.Allocator,
    path: []const u8,
    vocab_size: usize,
) ![]u32 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    if (stat.size == 0 or stat.size > 1 << 20) return error.InvalidUsage;
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(bytes);
    if (try file.readAll(bytes) != bytes.len) return error.InvalidUsage;

    var tokens: std.ArrayList(u32) = .empty;
    errdefer tokens.deinit(allocator);
    var iterator = std.mem.tokenizeAny(u8, bytes, " \n\r\t");
    while (iterator.next()) |text| {
        const token = std.fmt.parseInt(u32, text, 10) catch
            return error.InvalidUsage;
        if (token >= vocab_size) return error.InvalidUsage;
        try tokens.append(allocator, token);
    }
    if (tokens.items.len < width) return error.InvalidUsage;
    return try tokens.toOwnedSlice(allocator);
}

fn buildPrompts(
    allocator: std.mem.Allocator,
    base_tokens: []const u32,
    prompt_len: usize,
) ![width][]u32 {
    var prompts: [width][]u32 = undefined;
    var initialized: usize = 0;
    errdefer for (prompts[0..initialized]) |prompt| allocator.free(prompt);
    for (&prompts, 0..) |*prompt, lane| {
        prompt.* = try allocator.alloc(u32, prompt_len);
        initialized += 1;
        const lane_offset = (lane * 7) % base_tokens.len;
        for (prompt.*, 0..) |*token, index| {
            token.* = base_tokens[(lane_offset + index) % base_tokens.len];
        }
    }
    return prompts;
}

fn freePrompts(allocator: std.mem.Allocator, prompts: *[width][]u32) void {
    for (prompts) |prompt| allocator.free(prompt);
}

fn makeBindings(prompts: *const [width][]u32) [width]observation.RequestBinding {
    var bindings: [width]observation.RequestBinding = undefined;
    for (&bindings, 0..) |*binding, lane| {
        binding.* = .{
            .prompt = prompts[lane],
            .seed = 0x474c_4143_4945_5200 + lane + 1,
        };
    }
    return bindings;
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

fn deriveObservationBinding(
    model: engine.loader.LoadedModel,
    runner_artifact_sha256: [32]u8,
    model_artifact_sha256: [32]u8,
    terminal_kv_positions: usize,
    greedy_head_mode: engine.decode_lane4.GreedyHeadMode,
    attention_mode: engine.decode_lane4.AttentionMode,
    pair_down_mode: engine.decode_lane4.PairDownMode,
    bindings: [width]observation.RequestBinding,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-lane4-actual-model-smoke-v6\x00");
    hash.update(&runner_artifact_sha256);
    hash.update(&model_artifact_sha256);
    hash.update(&model.source_fingerprint);
    hashU64(&hash, observation.observation_abi);
    hashU64(&hash, engine.decode_lane4.abi);
    hashU64(&hash, engine.decode_lane4.greedy_head_abi);
    hashU64(&hash, engine.decode_lane4.projection_wave_abi);
    hashU64(&hash, engine.decode_lane4.shared_kv_attention_abi);
    hashU64(&hash, engine.decode_lane4.pair_down_wave_abi);
    hashU64(&hash, engine.token_txn.abi);
    hashU64(&hash, engine.token_txn.sink_abi);
    hashU64(&hash, engine.token_txn.prepare_ack_abi);
    hashU64(&hash, engine.token_txn.commit_receipt_abi);
    hashU64(&hash, runner_core.b4_token_txn_journal_abi);
    hashU64(&hash, @intFromEnum(greedy_head_mode));
    hashU64(&hash, @intFromEnum(attention_mode));
    hashU64(&hash, @intFromEnum(pair_down_mode));
    hashU64(&hash, engine.generate.request_execution_telemetry_abi);
    hashU64(&hash, runner_core.monotonic_clock_abi);
    hashU64(&hash, terminal_kv_positions);
    for (bindings, 0..) |binding, lane| {
        hashU32(&hash, @intCast(lane));
        hashU64(&hash, binding.seed);
        hashU64(&hash, binding.prompt.len);
        for (binding.prompt) |token| hashU32(&hash, token);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn tokensPerSecond(duration_ns: u64) !f64 {
    if (duration_ns == 0) return error.InvalidTiming;
    return @as(f64, @floatFromInt(width * new_tokens)) *
        @as(f64, std.time.ns_per_s) / @as(f64, @floatFromInt(duration_ns));
}

pub fn main() !void {
    if (builtin.cpu.arch != .aarch64) return error.AArch64Required;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 6 or args.len > 8) return error.InvalidUsage;

    const model_path = args[1];
    const ids_path = args[2];
    const terminal_kv_positions = try std.fmt.parseInt(usize, args[3], 10);
    const order = try ArmOrder.parse(args[4]);
    const greedy_head_mode = try parseGreedyHeadMode(args[5]);
    const attention_mode = if (args.len == 7)
        try parseAttentionMode(args[6])
    else if (args.len == 8)
        try parseAttentionMode(args[6])
    else
        engine.decode_lane4.AttentionMode.serial;
    const pair_down_mode = if (args.len == 8)
        try parsePairDownMode(args[7])
    else
        engine.decode_lane4.PairDownMode.split_control;
    if (terminal_kv_positions < new_tokens or
        terminal_kv_positions > engine.forward.max_attention_context)
        return error.InvalidUsage;
    const prompt_len = terminal_kv_positions - new_tokens + 1;

    const executable_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(executable_path);
    const runner_artifact = try hashFile(executable_path);
    const model_artifact = try hashFile(model_path);
    const ids_artifact = try hashFile(ids_path);

    var model = try engine.loader.loadPreparedWithOptions(
        allocator,
        model_path,
        .{ .mlp_layout = .pair_nibble_required },
    );
    defer model.deinit();
    const base_tokens = try readBaseTokens(
        allocator,
        ids_path,
        model.config.vocab_size,
    );
    defer allocator.free(base_tokens);
    var prompts = try buildPrompts(allocator, base_tokens, prompt_len);
    defer freePrompts(allocator, &prompts);
    const bindings = makeBindings(&prompts);
    const observation_binding = deriveObservationBinding(
        model,
        runner_artifact.sha256,
        model_artifact.sha256,
        terminal_kv_positions,
        greedy_head_mode,
        attention_mode,
        pair_down_mode,
        bindings,
    );

    var m1_result: ?observation.M1x4Observation = null;
    defer if (m1_result) |*result| result.deinit();
    var b4_result: ?observation.B4Observation = null;
    defer if (b4_result) |*result| result.deinit();

    const epoch_offset: u64 = @intCast(terminal_kv_positions);
    const m1_bank_epoch = 0x4d31_4241_4e4b_0000 + epoch_offset;
    const m1_barrier_epoch = 0x4d31_4241_5252_0000 + epoch_offset;
    const b4_bank_epoch = 0x4234_4241_4e4b_0000 + epoch_offset;
    switch (order) {
        .m1x4_b4 => {
            m1_result = try observation.runM1x4(
                allocator,
                model,
                bindings,
                .{
                    .observation_binding = observation_binding,
                    .bank_epoch = m1_bank_epoch,
                    .barrier_epoch = m1_barrier_epoch,
                },
            );
            b4_result = try observation.runB4(
                allocator,
                model,
                bindings,
                .{
                    .observation_binding = observation_binding,
                    .bank_epoch = b4_bank_epoch,
                    .greedy_head_mode = greedy_head_mode,
                    .attention_mode = attention_mode,
                    .pair_down_mode = pair_down_mode,
                },
            );
        },
        .b4_m1x4 => {
            b4_result = try observation.runB4(
                allocator,
                model,
                bindings,
                .{
                    .observation_binding = observation_binding,
                    .bank_epoch = b4_bank_epoch,
                    .greedy_head_mode = greedy_head_mode,
                    .attention_mode = attention_mode,
                    .pair_down_mode = pair_down_mode,
                },
            );
            m1_result = try observation.runM1x4(
                allocator,
                model,
                bindings,
                .{
                    .observation_binding = observation_binding,
                    .bank_epoch = m1_bank_epoch,
                    .barrier_epoch = m1_barrier_epoch,
                },
            );
        },
    }
    const m1 = &m1_result.?;
    const b4 = &b4_result.?;
    try observation.verifyCrossArmEquivalence(
        model,
        bindings,
        observation_binding,
        m1_bank_epoch,
        m1_barrier_epoch,
        b4_bank_epoch,
        greedy_head_mode,
        attention_mode,
        pair_down_mode,
        m1,
        b4,
    );

    // SinkV1 commit is infallible and intentionally performs no fallible clock
    // read. Use root start-to-join for both arms so the descriptive comparison
    // is symmetric and does not fabricate B4 publication timestamps.
    const m1_comparable_ns = m1.timing.run.durationNs();
    const b4_comparable_ns = b4.timing.run.durationNs();
    const m1_rate = try tokensPerSecond(m1_comparable_ns);
    const b4_rate = try tokensPerSecond(b4_comparable_ns);
    const descriptive_ratio = @as(f64, @floatFromInt(m1_comparable_ns)) /
        @as(f64, @floatFromInt(b4_comparable_ns));
    try requireUnchanged(executable_path, runner_artifact.stat);
    try requireUnchanged(model_path, model_artifact.stat);
    try requireUnchanged(ids_path, ids_artifact.stat);
    const runner_hex = std.fmt.bytesToHex(runner_artifact.sha256, .lower);
    const model_artifact_hex = std.fmt.bytesToHex(
        model_artifact.sha256,
        .lower,
    );
    const ids_hex = std.fmt.bytesToHex(ids_artifact.sha256, .lower);
    const source_hex = std.fmt.bytesToHex(model.source_fingerprint, .lower);
    const workload_hex = std.fmt.bytesToHex(m1.workload_binding, .lower);
    const observation_hex = std.fmt.bytesToHex(observation_binding, .lower);
    const b4_txn_initial_hex = std.fmt.bytesToHex(
        b4.token_txn_journal.initial_sha256,
        .lower,
    );
    const b4_txn_head_hex = std.fmt.bytesToHex(
        b4.token_txn_journal.head_sha256,
        .lower,
    );

    const stdout = std.fs.File.stdout();
    var output_buffer: [32 * 1024]u8 = undefined;
    var buffered = std.fs.File.Writer.init(stdout, &output_buffer);
    defer buffered.interface.flush() catch {};
    const writer = &buffered.interface;

    try writer.print(
        "{{\"schema\":\"{s}\",\"publishable\":false,\"reason\":\"one-measured-pair-with-fresh-threads-four-participants-no-abba-power-physical-or-quality-gate\",\"order\":\"{s}\",\"terminal_kv_positions\":{d},\"prompt_tokens_per_lane\":{d},\"new_tokens_per_lane\":{d},\"total_inference_participants\":{d},\"decode_lane4_abi\":\"{x:0>16}\",\"greedy_head_abi\":\"{x:0>16}\",\"projection_wave_abi\":\"{x:0>16}\",\"shared_kv_attention_abi\":\"{x:0>16}\",\"pair_down_wave_abi\":\"{x:0>16}\",\"token_txn_abi\":\"{x:0>16}\",\"token_txn_sink_abi\":\"{x:0>16}\",\"token_txn_prepare_ack_abi\":\"{x:0>16}\",\"token_txn_commit_receipt_abi\":\"{x:0>16}\",\"b4_token_txn_journal_abi\":\"{x:0>16}\",\"b4_greedy_head_mode\":\"{s}\",\"b4_attention_mode\":\"{s}\",\"b4_pair_down_mode\":\"{s}\",\"observation_abi\":\"{x:0>16}\",\"comparable_timing_basis\":\"root-start-through-root-join-both-arms\",\"runner_artifact_sha256\":\"{s}\",\"model_artifact_sha256\":\"{s}\",\"ids_artifact_sha256\":\"{s}\",\"model_source_sha256\":\"{s}\",\"workload_sha256\":\"{s}\",\"observation_binding_sha256\":\"{s}\",",
        .{
            schema,
            order.label(),
            terminal_kv_positions,
            prompt_len,
            new_tokens,
            width,
            engine.decode_lane4.abi,
            engine.decode_lane4.greedy_head_abi,
            engine.decode_lane4.projection_wave_abi,
            engine.decode_lane4.shared_kv_attention_abi,
            engine.decode_lane4.pair_down_wave_abi,
            engine.token_txn.abi,
            engine.token_txn.sink_abi,
            engine.token_txn.prepare_ack_abi,
            engine.token_txn.commit_receipt_abi,
            runner_core.b4_token_txn_journal_abi,
            greedyHeadModeLabel(greedy_head_mode),
            attentionModeLabel(attention_mode),
            pairDownModeLabel(pair_down_mode),
            observation.observation_abi,
            &runner_hex,
            &model_artifact_hex,
            &ids_hex,
            &source_hex,
            &workload_hex,
            &observation_hex,
        },
    );
    try writer.print(
        "\"m1x4\":{{\"comparable_root_run_ns\":{d},\"publication_timing_basis\":\"observer-commit-exact\",\"ttft_ns\":{d},\"exact_primary_publish_ns\":{d},\"postlude_ns\":{d},\"output_tokens_per_second\":{d:.6},\"logical_peak_host_bytes\":{d}}},",
        .{
            m1.timing.run.durationNs(),
            m1.timing.time_to_first_publish.durationNs(),
            m1.timing.primary_publish.durationNs(),
            m1.timing.postlude_join.durationNs(),
            m1_rate,
            m1.barrier.committed_snapshot.peak_host_bytes,
        },
    );
    try writer.print(
        "\"b4\":{{\"comparable_root_run_ns\":{d},\"publication_timing_basis\":\"root-completion-upper-bound-no-commit-clock\",\"commit_timestamps_available\":false,\"ttft_upper_bound_ns\":{d},\"primary_publish_upper_bound_ns\":{d},\"postlude_timing_available\":false,\"postlude_ns\":null,\"output_tokens_per_second\":{d:.6},\"logical_peak_host_bytes\":{d},\"publication_mode\":\"token-txn-required\",\"token_txn_request_epoch\":\"{x:0>16}\",\"token_txn_prepare_count\":{d},\"token_txn_commit_count\":{d},\"token_txn_abort_count\":{d},\"token_txn_lane_transitions\":{d},\"token_txn_kv_transitions\":{d},\"token_txn_first_sequence\":{d},\"token_txn_last_sequence\":{d},\"token_txn_all_live_mask\":\"1111\",\"token_txn_terminal_sequence\":63,\"token_txn_initial_sha256\":\"{s}\",\"token_txn_head_sha256\":\"{s}\",\"token_txn_bank_epoch\":\"{x:0>16}\",\"token_txn_bank_slot\":{d},\"token_txn_bank_generation\":{d},\"token_txn_bank_owner_key\":\"{x:0>16}\",\"token_txn_bank_integrity\":\"{x:0>16}\",",
        .{
            b4.timing.run.durationNs(),
            b4.timing.time_to_first_publish.durationNs(),
            b4.timing.primary_publish.durationNs(),
            b4_rate,
            b4.post_commit.committed_snapshot.peak_host_bytes,
            b4.token_txn_journal.request_epoch,
            b4.token_txn_journal.prepare_count,
            b4.token_txn_journal.commit_count,
            b4.token_txn_journal.abort_count,
            b4.token_txn_journal.lane_transition_count,
            b4.token_txn_journal.kv_transition_count,
            b4.token_txn_journal.first_sequence,
            b4.token_txn_journal.last_sequence,
            &b4_txn_initial_hex,
            &b4_txn_head_hex,
            b4.token_txn_journal.resource_receipt.bank_epoch,
            b4.token_txn_journal.resource_receipt.slot_index,
            b4.token_txn_journal.resource_receipt.generation,
            b4.token_txn_journal.resource_receipt.owner_key,
            b4.token_txn_journal.resource_receipt.integrity,
        },
    );
    try writer.print(
        "\"token_txn_provisional_abort_count\":{d},",
        .{b4.execution.token_txn_provisional_aborts},
    );
    try writer.print(
        "\"qkv_projection_waves\":{d},\"qkv_projection_joins_elided\":{d},\"shared_kv_lane_dispatches\":{d},\"shared_kv_tiles\":{d},\"pair_down_single_epochs\":{d},\"pair_down_split_worker_epochs\":{d},\"pair_down_joins_elided\":{d},\"pair_down_worker_tasks\":{d},\"pair_down_background_enqueues\":{d},\"pair_down_enqueue_rejects\":{d},\"materialized_head_dispatches\":{d},\"streaming_head_dispatches\":{d},\"streaming_head_tasks\":{d},\"streaming_head_shards\":{d},\"explicit_tile_score_scratch_bytes\":{d},\"materialized_logits_reclaimed_bytes\":{d}}},\"descriptive_b4_over_m1x4\":{d:.9},\"cross_arm_state_equal\":true,\"lane_states\":[",
        .{
            b4.execution.qkv_projection_waves,
            b4.execution.qkv_projection_joins_elided,
            b4.execution.shared_kv_attention_lane_dispatches,
            b4.execution.shared_kv_attention_tiles,
            b4.execution.pair_down_single_epochs,
            b4.execution.pair_down_split_worker_epochs,
            b4.execution.pair_down_joins_elided,
            b4.execution.pair_down_worker_tasks,
            b4.execution.pair_down_background_enqueues,
            b4.execution.pair_down_enqueue_rejects,
            b4.execution.materialized_lm_head_m4_dispatches,
            b4.execution.streaming_greedy_head_m4_dispatches,
            b4.execution.streaming_greedy_head_tasks,
            b4.execution.streaming_greedy_head_shards,
            b4.execution.streaming_greedy_head_tile_scratch_bytes,
            b4.execution.materialized_logits_reclaimed_bytes,
            descriptive_ratio,
        },
    );
    for (m1.generation_states, 0..) |state, lane| {
        if (lane != 0) try writer.writeAll(",");
        const kv_hex = std.fmt.bytesToHex(state.kv_sha256, .lower);
        const output_hex = std.fmt.bytesToHex(state.output_sha256, .lower);
        try writer.print(
            "{{\"lane\":{d},\"kv_sha256\":\"{s}\",\"output_sha256\":\"{s}\"}}",
            .{ lane, &kv_hex, &output_hex },
        );
    }
    try writer.writeAll("]}\n");
}
