//! Actual-model flat-capacity versus resident-child DecodeLane4 evidence.
//!
//! One process maps one immutable PairNibble GLRT and executes the fixed B4,
//! capacity-512, terminal-128 workload in a caller-selected balanced order.
//! The flat arm publishes PagedTokenTxn v1 against a full-capacity parent
//! receipt. The elastic arm publishes PagedElasticTokenTxn v2 against a
//! page-map parent plus a generation-fenced allocator-commitment child.
//!
//! This runner reports logical and allocator-commitment ledgers only. It makes
//! no OS RSS, resident-set, allocator-metadata, or physical-memory claim.
//!
//! Repository build graph (once the executable target imports this file):
//!   zig build -Doptimize=ReleaseFast -Dmetal=false
//! Usage:
//!   glacier-bench-paged-resident MODEL.glrt IDS \
//!     flat-elastic|elastic-flat|flat-only|elastic-only \
//!     materialized|streaming-required split-control|single-epoch-required

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");
const core = @import("core");

const schema = "glacier.decode-lane4/paged-resident-raw-v1";
const width = engine.decode_lane4.width;
const terminal_positions: usize = 128;
const capacity_positions: usize = 512;
const new_tokens: usize = 64;
const prompt_len: usize = terminal_positions - new_tokens + 1;
const expected_capacity_pages: usize =
    width * capacity_positions / engine.paged_kv_cache.page_positions;
const expected_live_pages: usize =
    width * terminal_positions / engine.paged_kv_cache.page_positions;
const expected_growth_waves: usize =
    terminal_positions / engine.paged_kv_cache.page_positions;

const Role = enum {
    flat,
    elastic,

    fn label(self: Role) []const u8 {
        return switch (self) {
            .flat => "flat-capacity",
            .elastic => "resident-child",
        };
    }
};

const Mode = enum {
    flat_elastic,
    elastic_flat,
    flat_only,
    elastic_only,

    fn parse(text: []const u8) !Mode {
        if (std.mem.eql(u8, text, "flat-elastic")) return .flat_elastic;
        if (std.mem.eql(u8, text, "elastic-flat")) return .elastic_flat;
        if (std.mem.eql(u8, text, "flat-only")) return .flat_only;
        if (std.mem.eql(u8, text, "elastic-only")) return .elastic_only;
        return error.InvalidUsage;
    }

    fn label(self: Mode) []const u8 {
        return switch (self) {
            .flat_elastic => "flat-elastic",
            .elastic_flat => "elastic-flat",
            .flat_only => "flat-only",
            .elastic_only => "elastic-only",
        };
    }

    fn isDual(self: Mode) bool {
        return self == .flat_elastic or self == .elastic_flat;
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
    var words = std.mem.tokenizeAny(u8, bytes, " \n\r\t");
    while (words.next()) |word| {
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

fn claimsEqualExceptKv(
    left: core.resource_bank.Claim,
    right: core.resource_bank.Claim,
) bool {
    var normalized = left;
    normalized.kv_bytes = right.kv_bytes;
    return std.meta.eql(normalized, right);
}

fn validateAdmissionPair(
    flat: engine.decode_lane4.ResourceAdmissionEnvelope,
    elastic: engine.decode_lane4.ResourceAdmissionEnvelope,
) !void {
    if (flat.paged_admission_mode != .flat_capacity or
        elastic.paged_admission_mode != .resident_child_required or
        flat.logical_kv_capacity_bytes != flat.parent_claim.kv_bytes or
        flat.logical_kv_capacity_bytes != elastic.logical_kv_capacity_bytes or
        !flat.child_ceiling.isZero() or flat.page_map_bytes != 0 or
        flat.bounded_peak_payload_bytes != 0 or
        !std.meta.eql(flat.parent_claim, flat.bounded_peak_claim) or
        elastic.parent_claim.kv_bytes != elastic.page_map_bytes or
        elastic.child_ceiling.kv_bytes + elastic.parent_claim.kv_bytes !=
            elastic.logical_kv_capacity_bytes or
        elastic.bounded_peak_claim.kv_bytes !=
            elastic.parent_claim.kv_bytes + elastic.bounded_peak_payload_bytes or
        elastic.bounded_peak_payload_bytes == 0 or
        elastic.parent_claim.kv_bytes >= elastic.bounded_peak_claim.kv_bytes or
        elastic.bounded_peak_claim.kv_bytes >=
            elastic.logical_kv_capacity_bytes or
        !claimsEqualExceptKv(flat.parent_claim, elastic.parent_claim) or
        !claimsEqualExceptKv(flat.parent_claim, elastic.bounded_peak_claim))
        return error.InvalidEvidence;
}

const SinkSummary = struct {
    prepare_count: usize = 0,
    commit_count: usize = 0,
    abort_count: usize = 0,
    lane_transitions: usize = 0,
    kv_transitions: usize = 0,
    last_sequence: u64 = 0,
    last_child_generation: u64 = 0,
    last_child_current_bytes: u64 = 0,
    head_sha256: [32]u8 = [_]u8{0} ** 32,
    valid: bool = true,
};

fn advanceHead(
    before: [32]u8,
    proposal: [32]u8,
    commit: [32]u8,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-paged-resident-sink-chain-v1\x00");
    hash.update(&before);
    hash.update(&proposal);
    hash.update(&commit);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn validateFlatProposal(
    proposal: engine.paged_token_txn.ProposalV1,
    expected: engine.decode_lane4.ResourceAdmissionEnvelope,
) bool {
    if (proposal.abi_version != engine.paged_token_txn.abi or
        proposal.resource_bank_abi != core.resource_bank.abi or
        proposal.resource_publication_fence_abi !=
            core.resource_bank.publication_fence_abi or
        proposal.paged_kv_abi != engine.paged_kv_cache.abi or
        proposal.page_map_root_abi != engine.paged_kv_cache.page_map_root_abi or
        proposal.page_ref_abi != engine.paged_kv_cache.page_ref_abi or
        proposal.page_transition_abi != engine.paged_token_txn.page_transition_abi or
        proposal.kv_row_txn_abi != engine.paged_kv_cache.row_txn_abi or
        proposal.execution_abi != engine.decode_lane4.paged_decode_abi or
        proposal.request_epoch == 0 or
        proposal.transaction_sequence >= new_tokens or
        proposal.resource_permit_generation == 0 or
        proposal.live_mask != 0b1111 or proposal.live_lane_count != width or
        proposal.kv_capacity_bytes != expected.logical_kv_capacity_bytes or
        !std.meta.eql(proposal.receipt.claim, expected.parent_claim))
        return false;

    var capacity_sum: u64 = 0;
    for (proposal.lanes, 0..) |lane, lane_index| {
        capacity_sum = std.math.add(u64, capacity_sum, lane.kv_capacity_bytes) catch
            return false;
        if (lane.lane_index != lane_index or
            lane.step_index != proposal.transaction_sequence or
            lane.prompt_len != prompt_len or
            lane.kv_after != prompt_len + proposal.transaction_sequence or
            lane.has_kv_transition != (proposal.transaction_sequence != 0) or
            lane.output_before != proposal.transaction_sequence or
            lane.output_after != proposal.transaction_sequence + 1 or
            lane.sampling_calls_before != proposal.transaction_sequence or
            lane.sampling_calls_after != proposal.transaction_sequence + 1 or
            lane.terminal !=
                (proposal.transaction_sequence + 1 == new_tokens) or
            lane.kv_transition.abi_version !=
                engine.paged_token_txn.page_transition_abi or
            lane.kv_transition.kv_row_txn_abi !=
                engine.paged_kv_cache.row_txn_abi or
            lane.kv_transition.page_map_root_abi !=
                engine.paged_kv_cache.page_map_root_abi or
            lane.kv_transition.page_ref_abi !=
                engine.paged_kv_cache.page_ref_abi)
            return false;
    }
    return capacity_sum == proposal.kv_capacity_bytes;
}

const FlatSink = struct {
    expected: ?engine.decode_lane4.ResourceAdmissionEnvelope = null,
    summary: SinkSummary = .{},
    pending: ?engine.paged_token_txn.ProposalV1 = null,
    pending_ack: ?engine.paged_token_txn.PrepareAckV1 = null,

    fn interface(self: *@This()) engine.paged_token_txn.SinkV1 {
        return .{ .context = self, .prepare = prepare, .commit = commit, .abort = abort };
    }

    fn prepare(
        context: *anyopaque,
        proposal: *const engine.paged_token_txn.ProposalV1,
        ack: *engine.paged_token_txn.PrepareAckV1,
    ) engine.paged_token_txn.SinkPrepareError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        const expected = self.expected orelse return error.InvalidEvidence;
        if (self.pending != null or !validateFlatProposal(proposal.*, expected))
            return error.InvalidEvidence;
        ack.* = .{
            .proposal_sha256 = engine.paged_token_txn.proposalSha256(proposal.*),
            .sink_epoch = 0x5032_464c_4154_0001,
            .reservation_id = proposal.transaction_sequence + 1,
        };
        self.pending = proposal.*;
        self.pending_ack = ack.*;
        self.summary.prepare_count += 1;
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
        const ack = self.pending_ack orelse {
            self.summary.valid = false;
            return;
        };
        const proposal_digest = engine.paged_token_txn.proposalSha256(
            receipt.proposal,
        );
        const commit_digest = engine.paged_token_txn.commitSha256(
            receipt.proposal_sha256,
            receipt.prepare_ack,
        );
        if (receipt.abi_version != engine.paged_token_txn.commit_receipt_abi or
            !std.meta.eql(pending, receipt.proposal) or
            !std.meta.eql(ack, receipt.prepare_ack) or
            receipt.prepare_ack.abi_version !=
                engine.paged_token_txn.prepare_ack_abi or
            !std.mem.eql(u8, &proposal_digest, &receipt.proposal_sha256) or
            !std.mem.eql(u8, &commit_digest, &receipt.commit_sha256))
            self.summary.valid = false;
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
        self.pending_ack = null;
    }

    fn abort(
        context: *anyopaque,
        proposal: *const engine.paged_token_txn.ProposalV1,
        ack: *const engine.paged_token_txn.PrepareAckV1,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.pending == null or self.pending_ack == null or
            !std.meta.eql(self.pending.?, proposal.*) or
            !std.meta.eql(self.pending_ack.?, ack.*))
            self.summary.valid = false;
        self.summary.abort_count += 1;
        self.pending = null;
        self.pending_ack = null;
    }
};

fn validateElasticProposal(
    proposal: engine.paged_elastic_token_txn.ProposalV2,
    expected: engine.decode_lane4.ResourceAdmissionEnvelope,
    prior_generation: u64,
    prior_current: u64,
) bool {
    const payload_grew = proposal.resident_payload_bytes > prior_current;
    if (proposal.abi_version != engine.paged_elastic_token_txn.abi or
        proposal.resource_bank_abi != core.resource_bank.abi or
        proposal.resource_child_lease_abi != core.resource_bank.child_lease_abi or
        proposal.resource_publication_fence_abi !=
            core.resource_bank.publication_fence_abi or
        proposal.paged_kv_abi != engine.paged_kv_cache.abi or
        proposal.page_map_root_abi != engine.paged_kv_cache.page_map_root_abi or
        proposal.page_ref_abi != engine.paged_kv_cache.page_ref_abi or
        proposal.page_transition_abi !=
            engine.paged_elastic_token_txn.page_transition_abi or
        proposal.kv_row_txn_abi != engine.paged_kv_cache.row_txn_abi or
        proposal.execution_abi != engine.decode_lane4.paged_resident_decode_abi or
        proposal.request_epoch == 0 or
        proposal.transaction_sequence >= new_tokens or
        proposal.resource_permit_generation == 0 or
        proposal.live_mask != 0b1111 or proposal.live_lane_count != width or
        proposal.logical_kv_capacity_bytes != expected.logical_kv_capacity_bytes or
        proposal.page_map_bytes != expected.page_map_bytes or
        proposal.resident_payload_bytes > expected.bounded_peak_payload_bytes or
        proposal.resident_payload_bytes < prior_current or
        proposal.resident_allocation_bytes !=
            proposal.page_map_bytes + proposal.resident_payload_bytes or
        !std.meta.eql(proposal.parent_receipt.claim, expected.parent_claim) or
        proposal.child_lease.abi_version != core.resource_bank.child_lease_abi or
        !std.meta.eql(proposal.child_lease.parent, proposal.parent_receipt) or
        !std.meta.eql(proposal.child_lease.ceiling, expected.child_ceiling) or
        !std.meta.eql(
            proposal.child_lease.claim,
            core.resource_bank.Claim{
                .kv_bytes = proposal.resident_payload_bytes,
            },
        ) or
        (payload_grew and proposal.child_lease.generation <= prior_generation) or
        (!payload_grew and proposal.child_lease.generation != prior_generation) or
        proposal.child_lease.generation == 0 or proposal.child_lease.integrity == 0)
        return false;

    var logical_sum: u64 = 0;
    var map_sum: u64 = 0;
    var payload_sum: u64 = 0;
    var allocation_sum: u64 = 0;
    for (proposal.lanes, 0..) |lane, lane_index| {
        logical_sum = std.math.add(u64, logical_sum, lane.logical_capacity_bytes) catch
            return false;
        map_sum = std.math.add(u64, map_sum, lane.page_map_bytes) catch
            return false;
        payload_sum = std.math.add(u64, payload_sum, lane.resident_payload_bytes) catch
            return false;
        allocation_sum = std.math.add(
            u64,
            allocation_sum,
            lane.resident_allocation_bytes,
        ) catch return false;
        if (lane.lane_index != lane_index or
            lane.step_index != proposal.transaction_sequence or
            lane.prompt_len != prompt_len or
            lane.kv_after != prompt_len + proposal.transaction_sequence or
            lane.has_kv_transition != (proposal.transaction_sequence != 0) or
            lane.output_before != proposal.transaction_sequence or
            lane.output_after != proposal.transaction_sequence + 1 or
            lane.sampling_calls_before != proposal.transaction_sequence or
            lane.sampling_calls_after != proposal.transaction_sequence + 1 or
            lane.terminal !=
                (proposal.transaction_sequence + 1 == new_tokens) or
            lane.resident_allocation_bytes !=
                lane.page_map_bytes + lane.resident_payload_bytes or
            lane.kv_transition.abi_version !=
                engine.paged_elastic_token_txn.page_transition_abi or
            lane.kv_transition.kv_row_txn_abi !=
                engine.paged_kv_cache.row_txn_abi or
            lane.kv_transition.page_map_root_abi !=
                engine.paged_kv_cache.page_map_root_abi or
            lane.kv_transition.page_ref_abi !=
                engine.paged_kv_cache.page_ref_abi)
            return false;
    }
    return logical_sum == proposal.logical_kv_capacity_bytes and
        map_sum == proposal.page_map_bytes and
        payload_sum == proposal.resident_payload_bytes and
        allocation_sum == proposal.resident_allocation_bytes;
}

const ElasticSink = struct {
    expected: ?engine.decode_lane4.ResourceAdmissionEnvelope = null,
    summary: SinkSummary = .{},
    pending: ?engine.paged_elastic_token_txn.ProposalV2 = null,
    pending_ack: ?engine.paged_elastic_token_txn.PrepareAckV2 = null,

    fn interface(self: *@This()) engine.paged_elastic_token_txn.SinkV2 {
        return .{ .context = self, .prepare = prepare, .commit = commit, .abort = abort };
    }

    fn prepare(
        context: *anyopaque,
        proposal: *const engine.paged_elastic_token_txn.ProposalV2,
        ack: *engine.paged_elastic_token_txn.PrepareAckV2,
    ) engine.paged_elastic_token_txn.SinkPrepareError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        const expected = self.expected orelse return error.InvalidEvidence;
        if (self.pending != null or !validateElasticProposal(
            proposal.*,
            expected,
            self.summary.last_child_generation,
            self.summary.last_child_current_bytes,
        )) return error.InvalidEvidence;
        ack.* = .{
            .proposal_sha256 = engine.paged_elastic_token_txn.proposalSha256(
                proposal.*,
            ),
            .sink_epoch = 0x5032_454c_4153_0002,
            .reservation_id = proposal.transaction_sequence + 1,
        };
        self.pending = proposal.*;
        self.pending_ack = ack.*;
        self.summary.prepare_count += 1;
    }

    fn commit(
        context: *anyopaque,
        receipt: *const engine.paged_elastic_token_txn.CommitReceiptV2,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        const pending = self.pending orelse {
            self.summary.valid = false;
            return;
        };
        const ack = self.pending_ack orelse {
            self.summary.valid = false;
            return;
        };
        const proposal_digest = engine.paged_elastic_token_txn.proposalSha256(
            receipt.proposal,
        );
        const commit_digest = engine.paged_elastic_token_txn.commitSha256(
            receipt.proposal_sha256,
            receipt.prepare_ack,
        );
        if (receipt.abi_version !=
            engine.paged_elastic_token_txn.commit_receipt_abi or
            !std.meta.eql(pending, receipt.proposal) or
            !std.meta.eql(ack, receipt.prepare_ack) or
            receipt.prepare_ack.abi_version !=
                engine.paged_elastic_token_txn.prepare_ack_abi or
            !std.mem.eql(u8, &proposal_digest, &receipt.proposal_sha256) or
            !std.mem.eql(u8, &commit_digest, &receipt.commit_sha256))
            self.summary.valid = false;
        self.summary.commit_count += 1;
        self.summary.lane_transitions += receipt.proposal.live_lane_count;
        for (receipt.proposal.lanes) |lane|
            self.summary.kv_transitions += @intFromBool(lane.has_kv_transition);
        self.summary.last_sequence = receipt.proposal.transaction_sequence;
        self.summary.last_child_generation = receipt.proposal.child_lease.generation;
        self.summary.last_child_current_bytes =
            receipt.proposal.child_lease.claim.kv_bytes;
        self.summary.head_sha256 = advanceHead(
            self.summary.head_sha256,
            receipt.proposal_sha256,
            receipt.commit_sha256,
        );
        self.pending = null;
        self.pending_ack = null;
    }

    fn abort(
        context: *anyopaque,
        proposal: *const engine.paged_elastic_token_txn.ProposalV2,
        ack: *const engine.paged_elastic_token_txn.PrepareAckV2,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.pending == null or self.pending_ack == null or
            !std.meta.eql(self.pending.?, proposal.*) or
            !std.meta.eql(self.pending_ack.?, ack.*))
            self.summary.valid = false;
        self.summary.abort_count += 1;
        self.pending = null;
        self.pending_ack = null;
    }
};

fn optionsForEnvelope(
    role: Role,
    flat_sink: *FlatSink,
    elastic_sink: *ElasticSink,
    head_mode: engine.decode_lane4.GreedyHeadMode,
    pair_down_mode: engine.decode_lane4.PairDownMode,
    epoch: u64,
) engine.decode_lane4.Options {
    return .{
        .num_threads = 4,
        .kv_cache_mode = .paged16_required,
        .paged_admission_mode = if (role == .flat)
            .flat_capacity
        else
            .resident_child_required,
        .kv_capacity_positions = capacity_positions,
        .greedy_head_mode = head_mode,
        .attention_mode = .serial,
        .pair_down_mode = pair_down_mode,
        .paged_token_txn_publication = if (role == .flat) .{
            .request_epoch = epoch,
            .sink = flat_sink.interface(),
        } else null,
        .paged_elastic_token_txn_publication = if (role == .elastic) .{
            .request_epoch = epoch,
            .sink = elastic_sink.interface(),
        } else null,
    };
}

fn deriveEnvelope(
    model: engine.loader.LoadedModel,
    requests: [width]engine.decode_lane4.Request,
    role: Role,
    head_mode: engine.decode_lane4.GreedyHeadMode,
    pair_down_mode: engine.decode_lane4.PairDownMode,
) !engine.decode_lane4.ResourceAdmissionEnvelope {
    var flat_sink: FlatSink = .{};
    var elastic_sink: ElasticSink = .{};
    return engine.decode_lane4.deriveResourceAdmissionEnvelope(
        model,
        requests,
        optionsForEnvelope(
            role,
            &flat_sink,
            &elastic_sink,
            head_mode,
            pair_down_mode,
            if (role == .flat) 0x5032_464c_0000_0001 else 0x5032_454c_0000_0001,
        ),
    );
}

const Run = struct {
    result: engine.decode_lane4.Result,
    telemetry: engine.decode_lane4.Telemetry,
    resources: engine.generate.RequestResourceTelemetry,
    envelope: engine.decode_lane4.ResourceAdmissionEnvelope,
    snapshot: core.resource_bank.SnapshotV2,
    sink: SinkSummary,
    duration_ns: u64,

    fn deinit(self: *Run) void {
        self.result.deinit();
    }
};

fn runRole(
    allocator: std.mem.Allocator,
    model: engine.loader.LoadedModel,
    requests: [width]engine.decode_lane4.Request,
    role: Role,
    expected: engine.decode_lane4.ResourceAdmissionEnvelope,
    head_mode: engine.decode_lane4.GreedyHeadMode,
    pair_down_mode: engine.decode_lane4.PairDownMode,
    epoch: u64,
) !Run {
    var flat_sink: FlatSink = .{};
    var elastic_sink: ElasticSink = .{};
    const base_options = optionsForEnvelope(
        role,
        &flat_sink,
        &elastic_sink,
        head_mode,
        pair_down_mode,
        epoch,
    );
    const envelope = try engine.decode_lane4.deriveResourceAdmissionEnvelope(
        model,
        requests,
        base_options,
    );
    if (!std.meta.eql(expected, envelope)) return error.InvalidEvidence;
    flat_sink.expected = envelope;
    elastic_sink.expected = envelope;
    const bank_claim = if (role == .flat)
        envelope.parent_claim
    else
        envelope.bounded_peak_claim;
    var slots: [width]core.resource_bank.Slot = undefined;
    var child_slots: [width]core.resource_bank.ChildSlot = undefined;
    var bank = if (role == .flat)
        try core.resource_bank.Bank.init(
            &slots,
            try exactLimits(bank_claim),
            epoch ^ 0x4241_4e4b_0000_0000,
        )
    else
        try core.resource_bank.Bank.initWithChildSlots(
            &slots,
            &child_slots,
            try exactLimits(bank_claim),
            epoch ^ 0x4241_4e4b_0000_0000,
        );
    var telemetry: engine.decode_lane4.Telemetry = .{};
    var resources: engine.generate.RequestResourceTelemetry = .{};
    var timer = try std.time.Timer.start();
    var result = try engine.decode_lane4.generate(
        allocator,
        model,
        requests,
        .{
            .num_threads = 4,
            .request_resource_bank = &bank,
            .resource_telemetry = &resources,
            .kv_cache_mode = .paged16_required,
            .paged_admission_mode = base_options.paged_admission_mode,
            .kv_capacity_positions = capacity_positions,
            .greedy_head_mode = head_mode,
            .attention_mode = .serial,
            .pair_down_mode = pair_down_mode,
            .paged_token_txn_publication = base_options.paged_token_txn_publication,
            .paged_elastic_token_txn_publication = base_options.paged_elastic_token_txn_publication,
            .telemetry = &telemetry,
        },
    );
    errdefer result.deinit();
    const duration_ns = timer.read();
    const snapshot = try bank.snapshotV2();
    return .{
        .result = result,
        .telemetry = telemetry,
        .resources = resources,
        .envelope = envelope,
        .snapshot = snapshot,
        .sink = if (role == .flat) flat_sink.summary else elastic_sink.summary,
        .duration_ns = duration_ns,
    };
}

fn rate(duration_ns: u64) !f64 {
    if (duration_ns == 0) return error.InvalidTiming;
    return @as(f64, @floatFromInt(width * new_tokens)) *
        @as(f64, std.time.ns_per_s) /
        @as(f64, @floatFromInt(duration_ns));
}

fn validateCompletedRun(run: *const Run, role: Role) !void {
    const expected_kv_transitions = width * (new_tokens - 1);
    const budget = if (role == .flat)
        run.envelope.parent_claim
    else
        run.envelope.bounded_peak_claim;
    if (run.telemetry.abi_version != engine.decode_lane4.abi or
        run.snapshot.abi_version != core.resource_bank.snapshot_abi or
        run.telemetry.kv_cache_mode != .paged16_required or
        run.telemetry.kv_capacity_positions != capacity_positions or
        run.telemetry.paged_kv_capacity_bytes !=
            run.envelope.logical_kv_capacity_bytes or
        run.telemetry.paged_kv_logical_capacity_bytes !=
            run.envelope.logical_kv_capacity_bytes or
        run.telemetry.paged_kv_resident_bytes >
            run.telemetry.paged_kv_capacity_bytes or
        run.telemetry.paged_kv_capacity_pages != expected_capacity_pages or
        run.telemetry.paged_kv_allocated_pages != expected_live_pages or
        run.telemetry.paged_kv_committed_pages != expected_live_pages or
        run.telemetry.paged_kv_reusable_pages != 0 or
        !run.sink.valid or run.sink.prepare_count != new_tokens or
        run.sink.commit_count != new_tokens or run.sink.abort_count != 0 or
        run.sink.last_sequence != new_tokens - 1 or
        run.sink.lane_transitions != width * new_tokens or
        run.sink.kv_transitions != expected_kv_transitions or
        !run.snapshot.used.isZero() or run.snapshot.active_reservations != 0 or
        run.snapshot.committed_receipts != 0 or
        run.snapshot.active_child_leases != 0 or
        !std.meta.eql(run.snapshot.limits, try exactLimits(budget)) or
        run.snapshot.peak.kv_bytes != budget.kv_bytes or
        run.snapshot.peak_host_bytes != try budget.hostBytes() or
        run.resources.host_limit_bytes != try budget.hostBytes() or
        run.resources.kv_bytes != run.envelope.parent_claim.kv_bytes or
        run.resources.active_reservations != 0 or
        run.resources.committed_receipts != 0 or
        run.resources.active_child_leases != 0 or
        run.resources.release_failures != 0)
        return error.InvalidEvidence;

    switch (role) {
        .flat => {
            if (run.telemetry.paged_admission_mode != .flat_capacity or
                run.telemetry.publication_mode != .paged_token_txn_required or
                run.telemetry.paged_decode_abi_version !=
                    engine.decode_lane4.paged_decode_abi or
                run.telemetry.paged_token_txn_abi_version !=
                    engine.paged_token_txn.abi or
                run.telemetry.paged_token_txn_sink_abi_version !=
                    engine.paged_token_txn.sink_abi or
                run.telemetry.paged_kv_page_map_commitment_bytes == 0 or
                run.snapshot.child_opens != 0 or run.snapshot.child_grows != 0 or
                run.snapshot.child_shrinks != 0 or run.snapshot.child_closes != 0 or
                run.snapshot.rejected_child_capacity != 0 or
                run.resources.child_lease_abi_version != 0 or
                run.resources.child_current_kv_bytes != 0 or
                run.resources.logical_kv_capacity_bytes != 0)
                return error.InvalidEvidence;
        },
        .elastic => {
            if (run.telemetry.paged_admission_mode != .resident_child_required or
                run.telemetry.publication_mode !=
                    .paged_elastic_token_txn_required or
                run.telemetry.paged_resident_decode_abi_version !=
                    engine.decode_lane4.paged_resident_decode_abi or
                run.telemetry.paged_elastic_token_txn_abi_version !=
                    engine.paged_elastic_token_txn.abi or
                run.telemetry.paged_elastic_token_txn_sink_abi_version !=
                    engine.paged_elastic_token_txn.sink_abi or
                run.telemetry.paged_kv_page_map_commitment_bytes !=
                    run.envelope.page_map_bytes or
                run.telemetry.paged_kv_child_current_bytes !=
                    run.envelope.bounded_peak_payload_bytes or
                run.telemetry.paged_kv_child_peak_bytes !=
                    run.envelope.bounded_peak_payload_bytes or
                run.telemetry.paged_kv_resident_bytes !=
                    run.envelope.page_map_bytes +
                        run.envelope.bounded_peak_payload_bytes or
                run.telemetry.paged_kv_child_growth_events !=
                    expected_growth_waves or
                run.telemetry.paged_kv_child_capacity_rejects != 0 or
                run.snapshot.child_opens != 1 or
                run.snapshot.child_grows != expected_growth_waves or
                run.snapshot.child_shrinks != 0 or run.snapshot.child_closes != 1 or
                run.snapshot.rejected_child_capacity != 0 or
                run.resources.child_lease_abi_version !=
                    core.resource_bank.child_lease_abi or
                run.resources.child_ceiling_kv_bytes !=
                    run.envelope.child_ceiling.kv_bytes or
                run.resources.child_current_kv_bytes !=
                    run.envelope.bounded_peak_payload_bytes or
                run.resources.logical_kv_capacity_bytes !=
                    run.envelope.logical_kv_capacity_bytes or
                run.resources.child_opens != run.snapshot.child_opens or
                run.resources.child_grows != run.snapshot.child_grows or
                run.resources.child_closes != run.snapshot.child_closes or
                run.resources.child_capacity_rejects != 0 or
                run.sink.last_child_current_bytes !=
                    run.envelope.bounded_peak_payload_bytes)
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

fn validateEqual(flat: *const Run, elastic: *const Run) !void {
    for (0..width) |lane|
        if (!std.mem.eql(u32, flat.result.tokens(lane), elastic.result.tokens(lane)))
            return error.StateMismatch;
    if (!std.meta.eql(flat.telemetry.lane_states, elastic.telemetry.lane_states))
        return error.StateMismatch;
    if (flat.telemetry.paged_kv_resident_bytes !=
        elastic.telemetry.paged_kv_resident_bytes or
        flat.telemetry.paged_kv_page_map_commitment_bytes !=
            elastic.telemetry.paged_kv_page_map_commitment_bytes)
        return error.AllocatorCommitmentMismatch;
}

fn writeRun(writer: anytype, name: []const u8, run: *const Run) !void {
    const head = std.fmt.bytesToHex(run.sink.head_sha256, .lower);
    try writer.print(
        "\"{s}\":{{\"role\":\"{s}\",\"run_ns\":{d},\"tokens_per_second\":{d:.6},\"parent_kv_bytes\":{d},\"logical_kv_capacity_bytes\":{d},\"envelope_page_map_bytes\":{d},\"page_map_commitment_bytes\":{d},\"allocator_commitment_at_completion_bytes\":{d},\"child_ceiling_kv_bytes\":{d},\"child_current_at_completion_bytes\":{d},\"bank_limit_kv_bytes\":{d},\"bank_peak_kv_bytes\":{d},\"bank_final_used_kv_bytes\":{d},\"bank_final_used_zero\":true,\"child_opens\":{d},\"child_grows\":{d},\"child_shrinks\":{d},\"child_closes\":{d},\"child_capacity_rejects\":{d},\"active_children_final\":{d},\"prepare_count\":{d},\"commit_count\":{d},\"kv_transitions\":{d},\"journal_head_sha256\":\"{s}\"}}",
        .{
            name,
            if (std.mem.eql(u8, name, "flat")) Role.flat.label() else Role.elastic.label(),
            run.duration_ns,
            try rate(run.duration_ns),
            run.envelope.parent_claim.kv_bytes,
            run.envelope.logical_kv_capacity_bytes,
            run.envelope.page_map_bytes,
            run.telemetry.paged_kv_page_map_commitment_bytes,
            run.telemetry.paged_kv_resident_bytes,
            run.envelope.child_ceiling.kv_bytes,
            run.resources.child_current_kv_bytes,
            run.snapshot.limits.kv_bytes,
            run.snapshot.peak.kv_bytes,
            run.snapshot.used.kv_bytes,
            run.snapshot.child_opens,
            run.snapshot.child_grows,
            run.snapshot.child_shrinks,
            run.snapshot.child_closes,
            run.snapshot.rejected_child_capacity,
            run.snapshot.active_child_leases,
            run.sink.prepare_count,
            run.sink.commit_count,
            run.sink.kv_transitions,
            &head,
        },
    );
}

fn writeLaneStates(writer: anytype, run: *const Run) !void {
    try writer.writeAll("\"lane_states\":[");
    for (run.telemetry.lane_states, 0..) |state, lane| {
        if (lane != 0) try writer.writeAll(",");
        const kv_hex = std.fmt.bytesToHex(state.kv_sha256, .lower);
        const output_hex = std.fmt.bytesToHex(state.output_sha256, .lower);
        try writer.print(
            "{{\"lane\":{d},\"complete\":true,\"kv_positions\":{d},\"sampling_calls\":{d},\"kv_sha256\":\"{s}\",\"output_sha256\":\"{s}\",\"rng_state\":[\"{x:0>16}\",\"{x:0>16}\",\"{x:0>16}\",\"{x:0>16}\"]}}",
            .{
                lane,
                state.kv_positions,
                state.sampling_calls,
                &kv_hex,
                &output_hex,
                state.rng_state[0],
                state.rng_state[1],
                state.rng_state[2],
                state.rng_state[3],
            },
        );
    }
    try writer.writeAll("]");
}

pub fn main() !void {
    if (builtin.cpu.arch != .aarch64) return error.AArch64Required;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 6) return error.InvalidUsage;

    const model_path = args[1];
    const ids_path = args[2];
    const mode = try Mode.parse(args[3]);
    const head_mode = try parseHead(args[4]);
    const pair_down_mode = try parsePairDown(args[5]);

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
    var prompts = try buildPrompts(allocator, ids);
    defer freePrompts(allocator, &prompts);
    const requests = makeRequests(&prompts);

    const flat_envelope = try deriveEnvelope(
        model,
        requests,
        .flat,
        head_mode,
        pair_down_mode,
    );
    const elastic_envelope = try deriveEnvelope(
        model,
        requests,
        .elastic,
        head_mode,
        pair_down_mode,
    );
    try validateAdmissionPair(flat_envelope, elastic_envelope);

    var flat: ?Run = null;
    defer if (flat) |*run| run.deinit();
    var elastic: ?Run = null;
    defer if (elastic) |*run| run.deinit();
    switch (mode) {
        .flat_elastic => {
            flat = try runRole(
                allocator,
                model,
                requests,
                .flat,
                flat_envelope,
                head_mode,
                pair_down_mode,
                0x5032_464c_0000_0101,
            );
            elastic = try runRole(
                allocator,
                model,
                requests,
                .elastic,
                elastic_envelope,
                head_mode,
                pair_down_mode,
                0x5032_454c_0000_0101,
            );
        },
        .elastic_flat => {
            elastic = try runRole(
                allocator,
                model,
                requests,
                .elastic,
                elastic_envelope,
                head_mode,
                pair_down_mode,
                0x5032_454c_0000_0201,
            );
            flat = try runRole(
                allocator,
                model,
                requests,
                .flat,
                flat_envelope,
                head_mode,
                pair_down_mode,
                0x5032_464c_0000_0201,
            );
        },
        .flat_only => flat = try runRole(
            allocator,
            model,
            requests,
            .flat,
            flat_envelope,
            head_mode,
            pair_down_mode,
            0x5032_464c_0000_0301,
        ),
        .elastic_only => elastic = try runRole(
            allocator,
            model,
            requests,
            .elastic,
            elastic_envelope,
            head_mode,
            pair_down_mode,
            0x5032_454c_0000_0401,
        ),
    }
    if (flat) |*run| try validateCompletedRun(run, .flat);
    if (elastic) |*run| try validateCompletedRun(run, .elastic);
    if (mode.isDual()) try validateEqual(&flat.?, &elastic.?);

    try requireUnchanged(executable_path, executable.stat);
    try requireUnchanged(model_path, model_file.stat);
    try requireUnchanged(ids_path, ids_file.stat);
    const executable_hex = std.fmt.bytesToHex(executable.sha256, .lower);
    const model_hex = std.fmt.bytesToHex(model_file.sha256, .lower);
    const ids_hex = std.fmt.bytesToHex(ids_file.sha256, .lower);
    const source_hex = std.fmt.bytesToHex(model.source_fingerprint, .lower);

    const stdout = std.fs.File.stdout();
    var output_buffer: [32 * 1024]u8 = undefined;
    var buffered = std.fs.File.Writer.init(stdout, &output_buffer);
    defer buffered.interface.flush() catch {};
    const writer = &buffered.interface;
    try writer.print(
        "{{\"schema\":\"{s}\",\"publishable\":false,\"reason\":\"raw-orderable-or-role-isolated-logical-and-allocator-commitment-evidence-no-os-physical-or-confidence-claim\",\"mode\":\"{s}\",\"cross_role_state_equal\":{s},\"terminal_kv_positions\":{d},\"capacity_kv_positions\":{d},\"prompt_tokens_per_lane\":{d},\"new_tokens_per_lane\":{d},\"head_mode\":\"{s}\",\"attention_mode\":\"serial\",\"pair_down_mode\":\"{s}\",\"runner_sha256\":\"{s}\",\"runner_size_bytes\":{d},\"model_sha256\":\"{s}\",\"model_size_bytes\":{d},\"ids_sha256\":\"{s}\",\"ids_size_bytes\":{d},\"model_source_sha256\":\"{s}\",\"abis\":{{\"decode_lane4\":\"{x:0>16}\",\"resource_bank\":\"{x:0>16}\",\"resource_child_lease\":\"{x:0>16}\",\"paged_decode_v1\":\"{x:0>16}\",\"paged_resident_decode_v2\":\"{x:0>16}\",\"paged_kv\":\"{x:0>16}\",\"paged_token_txn_v1\":\"{x:0>16}\",\"paged_elastic_token_txn_v2\":\"{x:0>16}\"}},",
        .{
            schema,
            mode.label(),
            if (mode.isDual()) "true" else "null",
            terminal_positions,
            capacity_positions,
            prompt_len,
            new_tokens,
            headLabel(head_mode),
            pairDownLabel(pair_down_mode),
            &executable_hex,
            executable.stat.size,
            &model_hex,
            model_file.stat.size,
            &ids_hex,
            ids_file.stat.size,
            &source_hex,
            engine.decode_lane4.abi,
            core.resource_bank.abi,
            core.resource_bank.child_lease_abi,
            engine.decode_lane4.paged_decode_abi,
            engine.decode_lane4.paged_resident_decode_abi,
            engine.paged_kv_cache.abi,
            engine.paged_token_txn.abi,
            engine.paged_elastic_token_txn.abi,
        },
    );
    try writer.print(
        "\"admission_proof\":{{\"flat_full_capacity_kv_bytes\":{d},\"elastic_parent_page_map_kv_bytes\":{d},\"elastic_logical_kv_capacity_bytes\":{d},\"elastic_child_ceiling_kv_bytes\":{d},\"elastic_bounded_peak_payload_bytes\":{d},\"elastic_bounded_peak_kv_bytes\":{d},\"bounded_peak_less_than_full\":true}},",
        .{
            flat_envelope.parent_claim.kv_bytes,
            elastic_envelope.parent_claim.kv_bytes,
            elastic_envelope.logical_kv_capacity_bytes,
            elastic_envelope.child_ceiling.kv_bytes,
            elastic_envelope.bounded_peak_payload_bytes,
            elastic_envelope.bounded_peak_claim.kv_bytes,
        },
    );
    var wrote_run = false;
    if (flat) |*run| {
        try writeRun(writer, "flat", run);
        wrote_run = true;
    }
    if (elastic) |*run| {
        if (wrote_run) try writer.writeAll(",");
        try writeRun(writer, "elastic", run);
        wrote_run = true;
    }
    if (mode.isDual()) try writer.print(
        ",\"elastic_over_flat_rate\":{d:.9}",
        .{try rate(elastic.?.duration_ns) / try rate(flat.?.duration_ns)},
    );
    try writer.writeAll(",");
    try writeLaneStates(writer, if (elastic) |*run| run else &flat.?);
    try writer.writeAll("}\n");
}
