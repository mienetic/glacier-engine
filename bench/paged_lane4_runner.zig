//! Actual-model contiguous-vs-paged DecodeLane4 diagnostic.
//!
//! One process loads one immutable PairNibble image, runs both strict B4
//! publication ABIs in a caller-selected order, and refuses output unless all
//! lane token/KV/output/RNG states match.  This is an orderable raw sample for
//! an external ABBA campaign, not publication-grade evidence by itself.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");
const core = @import("core");

const schema = "glacier.decode-lane4/paged-ab-raw-v1";
const width = engine.decode_lane4.width;
const new_tokens: usize = 64;

const Role = enum {
    contiguous,
    paged16_required,

    fn label(self: Role) []const u8 {
        return switch (self) {
            .contiguous => "contiguous",
            .paged16_required => "paged16-required",
        };
    }
};

const Order = enum {
    contiguous_paged,
    paged_contiguous,

    fn parse(text: []const u8) !Order {
        if (std.mem.eql(u8, text, "contiguous-paged"))
            return .contiguous_paged;
        if (std.mem.eql(u8, text, "paged-contiguous"))
            return .paged_contiguous;
        return error.InvalidUsage;
    }

    fn label(self: Order) []const u8 {
        return switch (self) {
            .contiguous_paged => "contiguous-paged",
            .paged_contiguous => "paged-contiguous",
        };
    }
};

fn parseHead(text: []const u8) !engine.decode_lane4.GreedyHeadMode {
    if (std.mem.eql(u8, text, "materialized")) return .materialized;
    if (std.mem.eql(u8, text, "streaming-required"))
        return .streaming_required;
    return error.InvalidUsage;
}

fn headLabel(mode: engine.decode_lane4.GreedyHeadMode) []const u8 {
    return switch (mode) {
        .materialized => "materialized",
        .streaming_required => "streaming-required",
    };
}

fn parsePairDown(text: []const u8) !engine.decode_lane4.PairDownMode {
    if (std.mem.eql(u8, text, "split-control")) return .split_control;
    if (std.mem.eql(u8, text, "single-epoch-required"))
        return .single_epoch_required;
    return error.InvalidUsage;
}

fn pairDownLabel(mode: engine.decode_lane4.PairDownMode) []const u8 {
    return switch (mode) {
        .split_control => "split-control",
        .single_epoch_required => "single-epoch-required",
    };
}

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
        const count = try file.pread(buffer[0..wanted], offset);
        if (count == 0) return error.UnexpectedEndOfFile;
        hash.update(buffer[0..count]);
        offset += count;
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

fn readIds(
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
    var ids: std.ArrayList(u32) = .empty;
    errdefer ids.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, bytes, " \n\r\t");
    while (it.next()) |word| {
        const token = std.fmt.parseInt(u32, word, 10) catch
            return error.InvalidUsage;
        if (token >= vocab_size) return error.InvalidUsage;
        try ids.append(allocator, token);
    }
    if (ids.items.len < width) return error.InvalidUsage;
    return ids.toOwnedSlice(allocator);
}

fn buildPrompts(
    allocator: std.mem.Allocator,
    ids: []const u32,
    prompt_len: usize,
) ![width][]u32 {
    var prompts: [width][]u32 = undefined;
    var initialized: usize = 0;
    errdefer for (prompts[0..initialized]) |prompt| allocator.free(prompt);
    for (&prompts, 0..) |*prompt, lane| {
        prompt.* = try allocator.alloc(u32, prompt_len);
        initialized += 1;
        const offset = lane * 7 % ids.len;
        for (prompt.*, 0..) |*token, index|
            token.* = ids[(offset + index) % ids.len];
    }
    return prompts;
}

fn freePrompts(allocator: std.mem.Allocator, prompts: *[width][]u32) void {
    for (prompts) |prompt| allocator.free(prompt);
}

fn makeRequests(prompts: *const [width][]u32) [width]engine.decode_lane4.Request {
    var requests: [width]engine.decode_lane4.Request = undefined;
    for (&requests, 0..) |*request, lane| request.* = .{
        .prompt = prompts[lane],
        .max_new_tokens = new_tokens,
        .eos_token = std.math.maxInt(u32),
        .sampler = .{ .temperature = 0 },
        .seed = 0x474c_4143_4945_5200 + lane + 1,
    };
    return requests;
}

const SinkSummary = struct {
    prepare_count: usize = 0,
    commit_count: usize = 0,
    abort_count: usize = 0,
    lane_transitions: usize = 0,
    kv_transitions: usize = 0,
    last_sequence: u64 = 0,
    head_sha256: [32]u8 = [_]u8{0} ** 32,
    valid: bool = true,
};

fn advanceHead(
    before: [32]u8,
    proposal: [32]u8,
    commit: [32]u8,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-paged-ab-sink-chain-v1\x00");
    hash.update(&before);
    hash.update(&proposal);
    hash.update(&commit);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

const ContiguousSink = struct {
    summary: SinkSummary = .{},
    pending: ?engine.token_txn.ProposalV1 = null,

    fn interface(self: *@This()) engine.token_txn.SinkV1 {
        return .{ .context = self, .prepare = prepare, .commit = commit, .abort = abort };
    }

    fn prepare(
        context: *anyopaque,
        proposal: *const engine.token_txn.ProposalV1,
        ack: *engine.token_txn.PrepareAckV1,
    ) engine.token_txn.SinkPrepareError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.pending != null) return error.CapacityExceeded;
        self.pending = proposal.*;
        self.summary.prepare_count += 1;
        ack.* = .{
            .proposal_sha256 = engine.token_txn.proposalSha256(proposal.*),
            .sink_epoch = 0x434f_4e54_4947_0001,
            .reservation_id = proposal.transaction_sequence + 1,
        };
    }

    fn commit(
        context: *anyopaque,
        receipt: *const engine.token_txn.CommitReceiptV1,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        const pending = self.pending orelse {
            self.summary.valid = false;
            return;
        };
        const proposal_digest = engine.token_txn.proposalSha256(receipt.proposal);
        if (!std.meta.eql(pending, receipt.proposal) or
            !std.mem.eql(u8, &proposal_digest, &receipt.proposal_sha256) or
            !std.mem.eql(
                u8,
                &engine.token_txn.commitSha256(
                    receipt.proposal_sha256,
                    receipt.prepare_ack,
                ),
                &receipt.commit_sha256,
            )) self.summary.valid = false;
        self.summary.commit_count += 1;
        self.summary.lane_transitions += receipt.proposal.live_lane_count;
        for (receipt.proposal.lanes) |lane|
            self.summary.kv_transitions += @intFromBool(lane.has_kv_transition);
        self.summary.last_sequence = receipt.proposal.transaction_sequence;
        self.summary.head_sha256 = advanceHead(
            self.summary.head_sha256,
            receipt.proposal_sha256,
            receipt.commit_sha256,
        );
        self.pending = null;
    }

    fn abort(
        context: *anyopaque,
        _: *const engine.token_txn.ProposalV1,
        _: *const engine.token_txn.PrepareAckV1,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.summary.abort_count += 1;
        self.pending = null;
    }
};

const PagedSink = struct {
    summary: SinkSummary = .{},
    pending: ?engine.paged_token_txn.ProposalV1 = null,

    fn interface(self: *@This()) engine.paged_token_txn.SinkV1 {
        return .{ .context = self, .prepare = prepare, .commit = commit, .abort = abort };
    }

    fn prepare(
        context: *anyopaque,
        proposal: *const engine.paged_token_txn.ProposalV1,
        ack: *engine.paged_token_txn.PrepareAckV1,
    ) engine.paged_token_txn.SinkPrepareError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.pending != null) return error.CapacityExceeded;
        self.pending = proposal.*;
        self.summary.prepare_count += 1;
        ack.* = .{
            .proposal_sha256 = engine.paged_token_txn.proposalSha256(proposal.*),
            .sink_epoch = 0x5041_4745_4947_0001,
            .reservation_id = proposal.transaction_sequence + 1,
        };
    }

    fn commit(
        context: *anyopaque,
        receipt: *const engine.paged_token_txn.CommitReceiptV1,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        const pending = self.pending orelse {
            self.summary.valid = false;
            return;
        };
        const proposal_digest = engine.paged_token_txn.proposalSha256(receipt.proposal);
        if (!std.meta.eql(pending, receipt.proposal) or
            !std.mem.eql(u8, &proposal_digest, &receipt.proposal_sha256) or
            !std.mem.eql(
                u8,
                &engine.paged_token_txn.commitSha256(
                    receipt.proposal_sha256,
                    receipt.prepare_ack,
                ),
                &receipt.commit_sha256,
            )) self.summary.valid = false;
        self.summary.commit_count += 1;
        self.summary.lane_transitions += receipt.proposal.live_lane_count;
        for (receipt.proposal.lanes) |lane|
            self.summary.kv_transitions += @intFromBool(lane.has_kv_transition);
        self.summary.last_sequence = receipt.proposal.transaction_sequence;
        self.summary.head_sha256 = advanceHead(
            self.summary.head_sha256,
            receipt.proposal_sha256,
            receipt.commit_sha256,
        );
        self.pending = null;
    }

    fn abort(
        context: *anyopaque,
        _: *const engine.paged_token_txn.ProposalV1,
        _: *const engine.paged_token_txn.PrepareAckV1,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.summary.abort_count += 1;
        self.pending = null;
    }
};

const Run = struct {
    result: engine.decode_lane4.Result,
    telemetry: engine.decode_lane4.Telemetry,
    resources: engine.generate.RequestResourceTelemetry,
    claim: core.resource_bank.Claim,
    snapshot: core.resource_bank.Snapshot,
    sink: SinkSummary,
    duration_ns: u64,

    fn deinit(self: *Run) void {
        self.result.deinit();
    }
};

fn exactLimits(claim: core.resource_bank.Claim) !core.resource_bank.Limits {
    return .{
        .host_bytes = try claim.hostBytes(),
        .capsule_bytes = claim.capsule_bytes,
        .kv_bytes = claim.kv_bytes,
        .activation_bytes = claim.activation_bytes,
        .partial_bytes = claim.partial_bytes,
        .logits_bytes = claim.logits_bytes,
        .output_journal_bytes = claim.output_journal_bytes,
        .staging_bytes = claim.staging_bytes,
        .device_bytes = claim.device_bytes,
        .io_bytes = claim.io_bytes,
        .queue_slots = claim.queue_slots,
    };
}

fn runRole(
    allocator: std.mem.Allocator,
    model: engine.loader.LoadedModel,
    requests: [width]engine.decode_lane4.Request,
    role: Role,
    capacity_positions: usize,
    head_mode: engine.decode_lane4.GreedyHeadMode,
    pair_down_mode: engine.decode_lane4.PairDownMode,
    epoch: u64,
) !Run {
    var contiguous_sink: ContiguousSink = .{};
    var paged_sink: PagedSink = .{};
    const base_options: engine.decode_lane4.Options = .{
        .num_threads = 4,
        .kv_cache_mode = if (role == .contiguous)
            .contiguous
        else
            .paged16_required,
        .kv_capacity_positions = capacity_positions,
        .greedy_head_mode = head_mode,
        .attention_mode = .serial,
        .pair_down_mode = pair_down_mode,
        .token_txn_publication = if (role == .contiguous) .{
            .request_epoch = epoch,
            .sink = contiguous_sink.interface(),
        } else null,
        .paged_token_txn_publication = if (role == .paged16_required) .{
            .request_epoch = epoch,
            .sink = paged_sink.interface(),
        } else null,
    };
    const claim = try engine.decode_lane4.deriveResourceClaim(
        model,
        requests,
        base_options,
    );
    var slots: [width]core.resource_bank.Slot = undefined;
    var bank = try core.resource_bank.Bank.init(
        &slots,
        try exactLimits(claim),
        epoch ^ 0x4241_4e4b_0000_0000,
    );
    var telemetry: engine.decode_lane4.Telemetry = .{};
    var resources: engine.generate.RequestResourceTelemetry = .{};
    var timer = try std.time.Timer.start();
    const result = try engine.decode_lane4.generate(
        allocator,
        model,
        requests,
        .{
            .num_threads = 4,
            .request_resource_bank = &bank,
            .resource_telemetry = &resources,
            .kv_cache_mode = base_options.kv_cache_mode,
            .kv_capacity_positions = capacity_positions,
            .greedy_head_mode = head_mode,
            .attention_mode = .serial,
            .pair_down_mode = pair_down_mode,
            .token_txn_publication = base_options.token_txn_publication,
            .paged_token_txn_publication = base_options.paged_token_txn_publication,
            .telemetry = &telemetry,
        },
    );
    const duration_ns = timer.read();
    const snapshot = try bank.snapshot();
    const summary = if (role == .contiguous)
        contiguous_sink.summary
    else
        paged_sink.summary;
    if (!summary.valid or summary.prepare_count != new_tokens or
        summary.commit_count != new_tokens or summary.abort_count != 0 or
        summary.last_sequence != new_tokens - 1 or !snapshot.used.isZero() or
        snapshot.committed_receipts != 0 or snapshot.active_reservations != 0)
        return error.InvalidEvidence;
    return .{
        .result = result,
        .telemetry = telemetry,
        .resources = resources,
        .claim = claim,
        .snapshot = snapshot,
        .sink = summary,
        .duration_ns = duration_ns,
    };
}

fn rate(duration_ns: u64) !f64 {
    if (duration_ns == 0) return error.InvalidTiming;
    return @as(f64, @floatFromInt(width * new_tokens)) *
        @as(f64, std.time.ns_per_s) /
        @as(f64, @floatFromInt(duration_ns));
}

fn validateCompletedRun(
    run: *const Run,
    role: Role,
    terminal_positions: usize,
    capacity_positions: usize,
) !void {
    const expected_kv_transitions = width * (new_tokens - 1);
    if (run.telemetry.abi_version != engine.decode_lane4.abi or
        run.telemetry.kv_capacity_positions != capacity_positions or
        run.sink.lane_transitions != width * new_tokens or
        run.sink.kv_transitions != expected_kv_transitions)
        return error.InvalidEvidence;

    switch (role) {
        .contiguous => {
            if (run.telemetry.kv_cache_mode != .contiguous or
                run.telemetry.publication_mode != .token_txn_required or
                run.telemetry.token_txn_abi_version != engine.token_txn.abi or
                run.telemetry.token_txn_sink_abi_version !=
                    engine.token_txn.sink_abi)
                return error.InvalidEvidence;
        },
        .paged16_required => {
            if (run.telemetry.kv_cache_mode != .paged16_required or
                run.telemetry.publication_mode !=
                    .paged_token_txn_required or
                run.telemetry.paged_decode_abi_version !=
                    engine.decode_lane4.paged_decode_abi or
                run.telemetry.paged_kv_abi_version !=
                    engine.paged_kv_cache.abi or
                run.telemetry.paged_token_txn_abi_version !=
                    engine.paged_token_txn.abi or
                run.telemetry.paged_token_txn_sink_abi_version !=
                    engine.paged_token_txn.sink_abi)
                return error.InvalidEvidence;
        },
    }

    const zero_digest = [_]u8{0} ** 32;
    const zero_rng = [_]u64{0} ** 4;
    for (run.telemetry.lane_states, 0..) |state, lane| {
        const tokens = run.result.tokens(lane);
        const output_digest = engine.generate.tokenSequenceSha256(tokens);
        if (tokens.len != new_tokens or !state.complete or
            state.abi_version != engine.generate.generation_state_abi or
            state.rng_abi != engine.generate.generation_rng_abi or
            state.kv_positions != terminal_positions or
            state.published_tokens != new_tokens or
            state.sampling_calls != new_tokens or
            std.mem.eql(u8, &state.kv_sha256, &zero_digest) or
            !std.mem.eql(u8, &state.output_sha256, &output_digest) or
            std.mem.eql(u64, &state.rng_state, &zero_rng))
            return error.InvalidEvidence;
    }
}

pub fn main() !void {
    if (builtin.cpu.arch != .aarch64) return error.AArch64Required;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 8) return error.InvalidUsage;

    const model_path = args[1];
    const ids_path = args[2];
    const terminal_positions = try std.fmt.parseInt(usize, args[3], 10);
    const capacity_positions = try std.fmt.parseInt(usize, args[4], 10);
    const order = try Order.parse(args[5]);
    const head_mode = try parseHead(args[6]);
    const pair_down_mode = try parsePairDown(args[7]);
    if (terminal_positions < new_tokens or
        terminal_positions > capacity_positions or
        capacity_positions > engine.forward.max_attention_context)
        return error.InvalidUsage;
    const prompt_len = terminal_positions - new_tokens + 1;

    const executable_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(executable_path);
    const executable = try hashFile(executable_path);
    const model_file = try hashFile(model_path);
    const ids_file = try hashFile(ids_path);
    var model = try engine.loader.loadPreparedWithOptions(
        allocator,
        model_path,
        .{ .mlp_layout = .pair_nibble_required },
    );
    defer model.deinit();
    const ids = try readIds(allocator, ids_path, model.config.vocab_size);
    defer allocator.free(ids);
    var prompts = try buildPrompts(allocator, ids, prompt_len);
    defer freePrompts(allocator, &prompts);
    const requests = makeRequests(&prompts);

    var contiguous: ?Run = null;
    defer if (contiguous) |*run| run.deinit();
    var paged: ?Run = null;
    defer if (paged) |*run| run.deinit();
    switch (order) {
        .contiguous_paged => {
            contiguous = try runRole(
                allocator,
                model,
                requests,
                .contiguous,
                capacity_positions,
                head_mode,
                pair_down_mode,
                0x434f_4e54_0000_0001 + terminal_positions,
            );
            paged = try runRole(
                allocator,
                model,
                requests,
                .paged16_required,
                capacity_positions,
                head_mode,
                pair_down_mode,
                0x5041_4745_0000_0001 + terminal_positions,
            );
        },
        .paged_contiguous => {
            paged = try runRole(
                allocator,
                model,
                requests,
                .paged16_required,
                capacity_positions,
                head_mode,
                pair_down_mode,
                0x5041_4745_0000_0001 + terminal_positions,
            );
            contiguous = try runRole(
                allocator,
                model,
                requests,
                .contiguous,
                capacity_positions,
                head_mode,
                pair_down_mode,
                0x434f_4e54_0000_0001 + terminal_positions,
            );
        },
    }
    const contiguous_run = &contiguous.?;
    const paged_run = &paged.?;
    try validateCompletedRun(
        contiguous_run,
        .contiguous,
        terminal_positions,
        capacity_positions,
    );
    try validateCompletedRun(
        paged_run,
        .paged16_required,
        terminal_positions,
        capacity_positions,
    );
    for (0..width) |lane|
        if (!std.mem.eql(
            u32,
            contiguous_run.result.tokens(lane),
            paged_run.result.tokens(lane),
        )) return error.StateMismatch;
    if (!std.meta.eql(
        contiguous_run.telemetry.lane_states,
        paged_run.telemetry.lane_states,
    )) return error.StateMismatch;
    if (paged_run.telemetry.paged_kv_capacity_bytes !=
        paged_run.claim.kv_bytes or
        paged_run.telemetry.paged_kv_resident_bytes >
            paged_run.telemetry.paged_kv_capacity_bytes)
        return error.InvalidEvidence;

    try requireUnchanged(executable_path, executable.stat);
    try requireUnchanged(model_path, model_file.stat);
    try requireUnchanged(ids_path, ids_file.stat);
    const executable_hex = std.fmt.bytesToHex(executable.sha256, .lower);
    const model_hex = std.fmt.bytesToHex(model_file.sha256, .lower);
    const ids_hex = std.fmt.bytesToHex(ids_file.sha256, .lower);
    const source_hex = std.fmt.bytesToHex(model.source_fingerprint, .lower);
    const contiguous_head = std.fmt.bytesToHex(
        contiguous_run.sink.head_sha256,
        .lower,
    );
    const paged_head = std.fmt.bytesToHex(
        paged_run.sink.head_sha256,
        .lower,
    );
    const stdout = std.fs.File.stdout();
    var output_buffer: [32 * 1024]u8 = undefined;
    var buffered = std.fs.File.Writer.init(stdout, &output_buffer);
    defer buffered.interface.flush() catch {};
    const writer = &buffered.interface;
    try writer.print(
        "{{\"schema\":\"{s}\",\"publishable\":false,\"reason\":\"single-orderable-same-process-pair-no-confidence-power-or-physical-gate\",\"order\":\"{s}\",\"terminal_kv_positions\":{d},\"capacity_kv_positions\":{d},\"prompt_tokens_per_lane\":{d},\"new_tokens_per_lane\":{d},\"head_mode\":\"{s}\",\"attention_mode\":\"serial\",\"pair_down_mode\":\"{s}\",\"runner_sha256\":\"{s}\",\"model_sha256\":\"{s}\",\"ids_sha256\":\"{s}\",\"model_source_sha256\":\"{s}\",\"decode_lane4_abi\":\"{x:0>16}\",\"paged_decode_abi\":\"{x:0>16}\",\"paged_kv_abi\":\"{x:0>16}\",\"paged_token_txn_abi\":\"{x:0>16}\",\"state_equal\":true,",
        .{
            schema,
            order.label(),
            terminal_positions,
            capacity_positions,
            prompt_len,
            new_tokens,
            headLabel(head_mode),
            pairDownLabel(pair_down_mode),
            &executable_hex,
            &model_hex,
            &ids_hex,
            &source_hex,
            engine.decode_lane4.abi,
            engine.decode_lane4.paged_decode_abi,
            engine.paged_kv_cache.abi,
            engine.paged_token_txn.abi,
        },
    );
    try writer.print(
        "\"contiguous\":{{\"run_ns\":{d},\"tokens_per_second\":{d:.6},\"kv_claim_bytes\":{d},\"peak_logical_host_bytes\":{d},\"prepare_count\":{d},\"commit_count\":{d},\"kv_transitions\":{d},\"journal_head_sha256\":\"{s}\"}},",
        .{
            contiguous_run.duration_ns,
            try rate(contiguous_run.duration_ns),
            contiguous_run.claim.kv_bytes,
            contiguous_run.snapshot.peak_host_bytes,
            contiguous_run.sink.prepare_count,
            contiguous_run.sink.commit_count,
            contiguous_run.sink.kv_transitions,
            &contiguous_head,
        },
    );
    try writer.print(
        "\"paged16\":{{\"run_ns\":{d},\"tokens_per_second\":{d:.6},\"kv_claim_bytes\":{d},\"kv_capacity_bytes\":{d},\"kv_resident_allocation_bytes\":{d},\"kv_committed_payload_bytes\":{d},\"capacity_pages\":{d},\"allocated_pages\":{d},\"committed_pages\":{d},\"reusable_pages\":{d},\"peak_logical_host_bytes\":{d},\"prepare_count\":{d},\"commit_count\":{d},\"kv_transitions\":{d},\"journal_head_sha256\":\"{s}\"}},\"paged_over_contiguous_rate\":{d:.9},\"lane_states\":[",
        .{
            paged_run.duration_ns,
            try rate(paged_run.duration_ns),
            paged_run.claim.kv_bytes,
            paged_run.telemetry.paged_kv_capacity_bytes,
            paged_run.telemetry.paged_kv_resident_bytes,
            paged_run.telemetry.paged_kv_committed_payload_bytes,
            paged_run.telemetry.paged_kv_capacity_pages,
            paged_run.telemetry.paged_kv_allocated_pages,
            paged_run.telemetry.paged_kv_committed_pages,
            paged_run.telemetry.paged_kv_reusable_pages,
            paged_run.snapshot.peak_host_bytes,
            paged_run.sink.prepare_count,
            paged_run.sink.commit_count,
            paged_run.sink.kv_transitions,
            &paged_head,
            try rate(paged_run.duration_ns) /
                try rate(contiguous_run.duration_ns),
        },
    );
    for (paged_run.telemetry.lane_states, 0..) |state, lane| {
        if (lane != 0) try writer.writeAll(",");
        const kv_hex = std.fmt.bytesToHex(state.kv_sha256, .lower);
        const output_hex = std.fmt.bytesToHex(state.output_sha256, .lower);
        try writer.print(
            "{{\"lane\":{d},\"kv_positions\":{d},\"kv_sha256\":\"{s}\",\"output_sha256\":\"{s}\"}}",
            .{ lane, state.kv_positions, &kv_hex, &output_hex },
        );
    }
    try writer.writeAll("]}\n");
}
