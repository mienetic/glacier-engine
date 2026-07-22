//! Actual-model PagedLeaseTokenTxn-v3 reclaim and admission evidence.
//!
//! The base executable runs one deterministic heterogeneous-EOS B4 cohort
//! under exact LeaseTree limits in both retain and immediate-reclaim order. The
//! admission executable freezes that real cohort after wave zero and runs a
//! second real cohort against the same live Bank, proving an exact byte-limit
//! rejection without reclaim and exact admission with reclaim. Both schemas
//! remain nonpublishable speed evidence: independent verification, fault
//! schedules, OS residency, energy, quality and cross-engine gates are open.
//!
//! Usage:
//!   glacier-bench-paged-lease MODEL.glrt IDS \
//!     retain-immediate|immediate-retain|retain-only|immediate-only \
//!     materialized split-control|single-epoch-required
//!   glacier-bench-paged-lease-admission MODEL.glrt IDS \
//!     retain-reclaim|reclaim-retain|retain-only|reclaim-only \
//!     materialized split-control|single-epoch-required

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");
const core = @import("core");
const runner_options = @import("paged_lease_runner_options");

const schema = "glacier.decode-lane4/paged-lease-actual-model-raw-v1";
const admission_schema =
    "glacier.decode-lane4/paged-lease-two-cohort-actual-model-raw-v1";
const width = engine.decode_lane4.width;
const prompt_len: usize = 128;
const admission_b_prompt_len: usize = 32;
const capacity_positions: usize = 512;
const eos_token: u32 = 0;
const non_eos_token: u32 = 1;
const max_new_tokens = [width]usize{ 2, 18, 34, 66 };
const published_tokens = [width]usize{ 1, 17, 33, 65 };
const terminal_positions = [width]usize{ 128, 144, 160, 192 };
const terminal_pages = [width]usize{ 8, 9, 10, 12 };
const total_published_tokens: usize = 116;
const total_kv_transitions: usize = total_published_tokens - width;
const expected_waves: usize = 65;
const max_lease_nodes: usize = 64;
const admission_lease_nodes: usize = 48;

const Policy = enum {
    retain,
    immediate,

    fn label(self: Policy) []const u8 {
        return switch (self) {
            .retain => "retain-until-teardown",
            .immediate => "terminal-immediate",
        };
    }

    fn engineValue(self: Policy) engine.decode_lane4.LeaseReclaimPolicy {
        return switch (self) {
            .retain => .retain_until_teardown,
            .immediate => .terminal_immediate,
        };
    }
};

const Mode = enum {
    retain_immediate,
    immediate_retain,
    retain_only,
    immediate_only,

    fn parse(text: []const u8) !Mode {
        if (std.mem.eql(u8, text, "retain-immediate"))
            return .retain_immediate;
        if (std.mem.eql(u8, text, "immediate-retain"))
            return .immediate_retain;
        if (std.mem.eql(u8, text, "retain-only")) return .retain_only;
        if (std.mem.eql(u8, text, "immediate-only")) return .immediate_only;
        return error.InvalidUsage;
    }

    fn label(self: Mode) []const u8 {
        return switch (self) {
            .retain_immediate => "retain-immediate",
            .immediate_retain => "immediate-retain",
            .retain_only => "retain-only",
            .immediate_only => "immediate-only",
        };
    }

    fn isDual(self: Mode) bool {
        return self == .retain_immediate or self == .immediate_retain;
    }
};

const AdmissionMode = enum {
    retain_reclaim,
    reclaim_retain,
    retain_only,
    reclaim_only,

    fn parse(text: []const u8) !AdmissionMode {
        if (std.mem.eql(u8, text, "retain-reclaim"))
            return .retain_reclaim;
        if (std.mem.eql(u8, text, "reclaim-retain"))
            return .reclaim_retain;
        if (std.mem.eql(u8, text, "retain-only")) return .retain_only;
        if (std.mem.eql(u8, text, "reclaim-only")) return .reclaim_only;
        return error.InvalidUsage;
    }

    fn label(self: AdmissionMode) []const u8 {
        return switch (self) {
            .retain_reclaim => "retain-reclaim",
            .reclaim_retain => "reclaim-retain",
            .retain_only => "retain-only",
            .reclaim_only => "reclaim-only",
        };
    }

    fn isDual(self: AdmissionMode) bool {
        return self == .retain_reclaim or self == .reclaim_retain;
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
        if (token >= vocab_size or token == eos_token)
            return error.InvalidUsage;
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

fn buildRequests(
    prompts: *const [width][]u32,
    forced: *[width][max_new_tokens[width - 1]]u32,
) [width]engine.decode_lane4.Request {
    var requests: [width]engine.decode_lane4.Request = undefined;
    for (&requests, 0..) |*request, lane| {
        @memset(&forced[lane], non_eos_token);
        forced[lane][published_tokens[lane] - 1] = eos_token;
        request.* = .{
            .prompt = prompts[lane],
            .max_new_tokens = max_new_tokens[lane],
            .eos_token = eos_token,
            .sampler = .{ .temperature = 0 },
            .seed = 0x474c_4143_4945_5200 + lane + 1,
            .forced_tokens = forced[lane][0..max_new_tokens[lane]],
        };
    }
    return requests;
}

fn buildAdmissionBPrompts(
    allocator: std.mem.Allocator,
    ids: []const u32,
) ![width][]u32 {
    var prompts: [width][]u32 = undefined;
    var initialized: usize = 0;
    errdefer for (prompts[0..initialized]) |prompt| allocator.free(prompt);
    for (&prompts, 0..) |*prompt, lane| {
        prompt.* = try allocator.alloc(u32, admission_b_prompt_len);
        initialized += 1;
        const offset = (lane * 11 + 3) % ids.len;
        for (prompt.*, 0..) |*token, index|
            token.* = ids[(offset + index) % ids.len];
    }
    return prompts;
}

fn buildAdmissionBRequests(
    prompts: *const [width][]u32,
    forced: *[width][2]u32,
) [width]engine.decode_lane4.Request {
    var requests: [width]engine.decode_lane4.Request = undefined;
    for (&requests, 0..) |*request, lane| {
        forced[lane] = .{ eos_token, eos_token };
        request.* = .{
            .prompt = prompts[lane],
            .max_new_tokens = 2,
            .eos_token = eos_token,
            .sampler = .{ .temperature = 0 },
            .seed = 0x474c_4143_4942_0000 + lane + 1,
            .forced_tokens = &forced[lane],
        };
    }
    return requests;
}

fn expectedAdmissionBRng(lane: usize) [4]u64 {
    std.debug.assert(lane < width);
    return std.Random.DefaultPrng.init(
        0x474c_4143_4942_0000 + lane + 1,
    ).s;
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

fn zeroDigest(digest: [32]u8) bool {
    return std.mem.eql(u8, &digest, &([_]u8{0} ** 32));
}

fn pagesForPositions(positions: usize) usize {
    return positions / engine.paged_kv_cache.page_positions +
        @intFromBool(positions % engine.paged_kv_cache.page_positions != 0);
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

fn expectedOutputSha256(lane: usize, output_after: usize) [32]u8 {
    std.debug.assert(lane < width);
    std.debug.assert(output_after > 0 and
        output_after <= published_tokens[lane]);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-output-token-state-v1\x00");
    hashU64(&hash, @intCast(output_after));
    for (0..output_after) |index| hashU32(
        &hash,
        if (index + 1 == published_tokens[lane]) eos_token else non_eos_token,
    );
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn expectedInitialRng(lane: usize) [4]u64 {
    std.debug.assert(lane < width);
    return std.Random.DefaultPrng.init(
        0x474c_4143_4945_5200 + lane + 1,
    ).s;
}

fn expectedMask(sequence: usize) u8 {
    var mask: u8 = 0;
    for (published_tokens, 0..) |count, lane| {
        if (sequence < count) {
            mask |= @as(u8, 1) << @intCast(lane);
        }
    }
    return mask;
}

fn expectedLifecycle(
    policy: Policy,
    sequence: usize,
    lane: usize,
) engine.leased_paged_kv_cache.LeaseLifecycle {
    if (sequence < published_tokens[lane]) return .live;
    return if (policy == .retain) .terminal_retained else .reclaimed;
}

fn expectedResourcePages(policy: Policy, sequence: usize, lane: usize) usize {
    if (sequence < published_tokens[lane])
        return pagesForPositions(prompt_len + sequence);
    return if (policy == .retain) terminal_pages[lane] else 0;
}

fn expectedTreePayloadBytes(
    policy: Policy,
    sequence: usize,
    page_payload_bytes: u64,
) u64 {
    var pages: u64 = 0;
    for (0..width) |lane|
        pages += @intCast(expectedResourcePages(policy, sequence, lane));
    return pages * page_payload_bytes;
}

fn expectedActiveNodes(policy: Policy, sequence: usize) u32 {
    var pages: usize = 0;
    for (0..width) |lane|
        pages += expectedResourcePages(policy, sequence, lane);
    // Lane scopes remain as zero-charge tombstones until tree teardown so a
    // reclaimed lane cannot make a stale scope handle address a reused node.
    return @intCast(width + pages);
}

fn expectedTreeStructureChanged(policy: Policy, sequence: usize) bool {
    if (sequence == 0) return true;
    for (0..width) |lane|
        if (expectedResourcePages(policy, sequence, lane) !=
            expectedResourcePages(policy, sequence - 1, lane))
            return true;
    return false;
}

const TreeTransitionDelta = struct {
    allocation_batches: usize = 0,
    reclaimed_scopes: usize = 0,
    generation: u64 = 0,
    structural_revision: u64 = 0,
};

/// Exact LeaseTree mutation cost for this fresh, no-abort fixture. A one-page
/// allocation batch reserves four generations and advances structural revision
/// twice; one complete subtree reclaim reserves five generations and advances
/// structural revision three times.
fn expectedTreeTransitionDelta(
    policy: Policy,
    sequence: usize,
) TreeTransitionDelta {
    std.debug.assert(sequence > 0 and sequence < expected_waves);
    var allocation_batches: usize = 0;
    var reclaimed_scopes: usize = 0;
    for (0..width) |lane| {
        const before = expectedResourcePages(policy, sequence - 1, lane);
        const after = expectedResourcePages(policy, sequence, lane);
        if (after > before) {
            std.debug.assert(after == before + 1);
            allocation_batches += 1;
        } else if (after < before) {
            std.debug.assert(policy == .immediate and after == 0);
            reclaimed_scopes += 1;
        }
    }
    return .{
        .allocation_batches = allocation_batches,
        .reclaimed_scopes = reclaimed_scopes,
        .generation = @as(u64, @intCast(allocation_batches)) * 4 +
            @as(u64, @intCast(reclaimed_scopes)) * 5,
        .structural_revision = @as(u64, @intCast(allocation_batches)) * 2 +
            @as(u64, @intCast(reclaimed_scopes)) * 3,
    };
}

fn expectedRootGeneration(sequence: usize, lane: usize) u64 {
    const committed_len = if (sequence < published_tokens[lane])
        prompt_len + sequence
    else
        terminal_positions[lane];
    // Fresh PagedKV root generation is one; every committed prompt/decode row
    // advances it exactly once, and this runner admits no abort/retry path.
    return @as(u64, @intCast(committed_len)) + 1;
}

fn rootMatchesTransitionAfter(
    root: engine.paged_kv_cache.PageMapRootV1,
    transition: engine.paged_lease_token_txn.RootTransitionV3,
) bool {
    return root.cache_instance == transition.cache_instance and
        root.generation == transition.root_after_generation and
        root.committed_len == transition.root_after_len and
        root.committed_pages == transition.root_after_pages and
        std.mem.eql(
            u8,
            &root.ownership_sha256,
            &transition.root_after_ownership_sha256,
        );
}

fn transitionBeforeMatchesRoot(
    transition: engine.paged_lease_token_txn.RootTransitionV3,
    root: engine.paged_kv_cache.PageMapRootV1,
) bool {
    return transition.cache_instance == root.cache_instance and
        transition.root_before_generation == root.generation and
        transition.root_before_len == root.committed_len and
        transition.root_before_pages == root.committed_pages and
        std.mem.eql(
            u8,
            &transition.root_before_ownership_sha256,
            &root.ownership_sha256,
        );
}

const WaveSummary = struct {
    sequence: u64 = 0,
    live_mask: u8 = 0,
    terminal_mask: u8 = 0,
    live_lane_count: u8 = 0,
    tree_payload_bytes: u64 = 0,
    active_nodes: u32 = 0,
    proposal_sha256: [32]u8 = [_]u8{0} ** 32,
    commit_sha256: [32]u8 = [_]u8{0} ** 32,
};

fn advanceHead(
    before: [32]u8,
    proposal: [32]u8,
    commit: [32]u8,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-paged-lease-runner-chain-v1\x00");
    hash.update(&before);
    hash.update(&proposal);
    hash.update(&commit);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

const Sink = struct {
    policy: Policy,
    expected_envelope: ?engine.decode_lane4.ResourceAdmissionEnvelope = null,
    expected_request_epoch: u64,
    page_payload_bytes: u64,
    allow_external_generation_gaps: bool = false,
    prepare_count: usize = 0,
    commit_count: usize = 0,
    abort_count: usize = 0,
    lane_transitions: usize = 0,
    kv_transitions: usize = 0,
    terminal_seals: usize = 0,
    valid: bool = true,
    pending: bool = false,
    pending_proposal_sha256: [32]u8 = [_]u8{0} ** 32,
    pending_ack: engine.paged_lease_token_txn.PrepareAckV3 = .{},
    cohort_initialized: bool = false,
    parent_receipt: ?core.resource_bank.Receipt = null,
    coordinator_instances: [width]u64 = [_]u64{0} ** width,
    cache_instances: [width]u64 = [_]u64{0} ** width,
    scope_indices: [width]u32 = [_]u32{0} ** width,
    scope_generations: [width]u64 = [_]u64{0} ** width,
    last_roots: [width]?engine.paged_kv_cache.PageMapRootV1 =
        [_]?engine.paged_kv_cache.PageMapRootV1{null} ** width,
    last_state_chains: [width][32]u8 = [_][32]u8{
        [_]u8{0} ** 32,
    } ** width,
    last_binding_summaries: [width]engine.leased_paged_kv_cache.BindingSummaryV1 =
        [_]engine.leased_paged_kv_cache.BindingSummaryV1{.{
            .count = 0,
            .payload_bytes = 0,
            .digest = [_]u8{0} ** 32,
        }} ** width,
    last_allocation_sets: [width]engine.leased_paged_kv_cache.AllocationSetCommitmentV2 =
        [_]engine.leased_paged_kv_cache.AllocationSetCommitmentV2{.{
            .count = 0,
            .payload_bytes = 0,
            .sha256 = [_]u8{0} ** 32,
        }} ** width,
    last_output_sha256: [width][32]u8 = [_][32]u8{
        [_]u8{0} ** 32,
    } ** width,
    last_rng: [width][4]u64 = [_][4]u64{[_]u64{0} ** 4} ** width,
    last_sampling_calls: [width]u64 = [_]u64{0} ** width,
    terminal_canonical_sha256: [width][32]u8 = [_][32]u8{
        [_]u8{0} ** 32,
    } ** width,
    tree_key: u64 = 0,
    tree_identity_generation: u64 = 0,
    last_tree_generation: u64 = 0,
    last_tree_structural_revision: u64 = 0,
    last_tree_payload_bytes: u64 = 0,
    last_tree_active_nodes: u32 = 0,
    last_tree_state_digest: u64 = 0,
    last_tree_token_integrity: u64 = 0,
    last_resource_permit_generation: u64 = 0,
    waves: [expected_waves]WaveSummary =
        [_]WaveSummary{.{}} ** expected_waves,
    head_sha256: [32]u8 = [_]u8{0} ** 32,

    fn interface(self: *@This()) engine.paged_lease_token_txn.SinkV3 {
        return .{
            .context = self,
            .prepare = prepare,
            .commit = commit,
            .abort = abort,
        };
    }

    fn fromContext(context: *anyopaque) *@This() {
        return @ptrCast(@alignCast(context));
    }

    fn validateProposal(
        self: *@This(),
        proposal: engine.paged_lease_token_txn.ProposalV3,
    ) bool {
        const expected_envelope = self.expected_envelope orelse return false;
        const sequence = std.math.cast(usize, proposal.transaction_sequence) orelse
            return false;
        if (sequence >= expected_waves or sequence != self.commit_count or
            proposal.abi_version != engine.paged_lease_token_txn.abi or
            proposal.resource_bank_abi != core.resource_bank.abi or
            proposal.resource_lease_tree_abi != core.resource_bank.lease_tree_abi or
            proposal.resource_publication_fence_abi !=
                core.resource_bank.publication_fence_abi or
            proposal.leased_paged_kv_abi != engine.leased_paged_kv_cache.abi or
            proposal.paged_kv_abi != engine.paged_kv_cache.abi or
            proposal.page_transition_abi !=
                engine.paged_lease_token_txn.page_transition_abi or
            proposal.execution_abi != engine.decode_lane4.paged_lease_decode_abi or
            proposal.request_epoch != self.expected_request_epoch or
            proposal.resource_permit_generation !=
                @as(u64, @intCast(sequence)) + 1 or
            proposal.live_mask != expectedMask(sequence) or
            proposal.live_lane_count != @popCount(proposal.live_mask) or
            !std.meta.eql(
                proposal.parent_receipt.claim,
                expected_envelope.parent_claim,
            ) or proposal.parent_receipt.bank_epoch == 0 or
            proposal.parent_receipt.slot_index != 0 or
            proposal.parent_receipt.generation == 0 or
            proposal.parent_receipt.owner_key == 0 or
            proposal.parent_receipt.integrity == 0 or
            proposal.tree.abi_version !=
                engine.paged_lease_token_txn.tree_commitment_abi or
            !std.meta.eql(
                proposal.tree.ceiling,
                expected_envelope.lease_tree_ceiling,
            ) or proposal.tree.current.kv_bytes != expectedTreePayloadBytes(
            self.policy,
            sequence,
            self.page_payload_bytes,
        ) or proposal.tree.current.capsule_bytes != 0 or
            proposal.tree.current.activation_bytes != 0 or
            proposal.tree.current.partial_bytes != 0 or
            proposal.tree.current.logits_bytes != 0 or
            proposal.tree.current.output_journal_bytes != 0 or
            proposal.tree.current.staging_bytes != 0 or
            proposal.tree.current.device_bytes != 0 or
            proposal.tree.current.io_bytes != 0 or
            proposal.tree.current.queue_slots != 0 or
            proposal.tree.tree_key == 0 or
            proposal.tree.identity_generation == 0 or
            proposal.tree.generation == 0 or
            proposal.tree.structural_revision == 0 or
            (!self.cohort_initialized and
                proposal.tree.structural_revision !=
                    1 + @as(u64, width) +
                        2 * (@as(
                            u64,
                            expectedActiveNodes(self.policy, 0),
                        ) - @as(u64, width))) or
            proposal.tree.active_nodes != expectedActiveNodes(
                self.policy,
                sequence,
            ) or
            proposal.tree.state_digest == 0 or proposal.tree.token_integrity == 0)
            return false;

        if (self.cohort_initialized) {
            if (!std.meta.eql(
                proposal.parent_receipt,
                self.parent_receipt orelse return false,
            ) or proposal.tree.tree_key != self.tree_key or
                proposal.tree.identity_generation !=
                    self.tree_identity_generation or
                proposal.resource_permit_generation !=
                    self.last_resource_permit_generation + 1)
                return false;
            const tree_changed = expectedTreeStructureChanged(
                self.policy,
                sequence,
            );
            const delta = expectedTreeTransitionDelta(self.policy, sequence);
            const expected_tree_generation = std.math.add(
                u64,
                self.last_tree_generation,
                delta.generation,
            ) catch return false;
            const expected_tree_revision = std.math.add(
                u64,
                self.last_tree_structural_revision,
                delta.structural_revision,
            ) catch return false;
            if (tree_changed) {
                if (delta.generation == 0 or delta.structural_revision == 0 or
                    (if (self.allow_external_generation_gaps)
                        proposal.tree.generation < expected_tree_generation
                    else
                        proposal.tree.generation != expected_tree_generation) or
                    proposal.tree.structural_revision != expected_tree_revision or
                    proposal.tree.state_digest == self.last_tree_state_digest or
                    proposal.tree.token_integrity ==
                        self.last_tree_token_integrity)
                    return false;
            } else if (delta.generation != 0 or delta.structural_revision != 0 or
                proposal.tree.generation != expected_tree_generation or
                proposal.tree.structural_revision != expected_tree_revision or
                proposal.tree.current.kv_bytes != self.last_tree_payload_bytes or
                proposal.tree.active_nodes != self.last_tree_active_nodes or
                proposal.tree.state_digest != self.last_tree_state_digest or
                proposal.tree.token_integrity != self.last_tree_token_integrity)
                return false;
        }

        var total_payload: u64 = 0;
        for (proposal.resources, 0..) |resource, lane| {
            const lifecycle = expectedLifecycle(self.policy, sequence, lane);
            const expected_pages = expectedResourcePages(
                self.policy,
                sequence,
                lane,
            );
            const expected_root_len = if (sequence < published_tokens[lane])
                prompt_len + sequence
            else
                terminal_positions[lane];
            if (resource.abi_version !=
                engine.paged_lease_token_txn.resource_commitment_abi or
                resource.lane_index != lane or resource.lifecycle != lifecycle or
                resource.coordinator_instance == 0 or
                resource.cache_instance == 0 or
                resource.scope_index != @as(u32, @intCast(lane)) or
                resource.scope_index >= expected_envelope.required_lease_nodes or
                resource.scope_generation == 0 or
                resource.root.abi_version !=
                    engine.paged_kv_cache.page_map_root_abi or
                resource.root.cache_instance != resource.cache_instance or
                resource.root.generation != expectedRootGeneration(sequence, lane) or
                resource.root.committed_len != expected_root_len or
                resource.root.committed_pages !=
                    pagesForPositions(expected_root_len) or
                zeroDigest(resource.root.ownership_sha256) or
                zeroDigest(resource.kv_state_chain_after) or
                resource.has_binding_summary != (expected_pages != 0) or
                (resource.has_binding_summary and
                    (resource.binding_summary.count != expected_pages or
                        resource.binding_summary.payload_bytes !=
                            @as(u64, @intCast(expected_pages)) *
                                self.page_payload_bytes or
                        zeroDigest(resource.binding_summary.digest))) or
                (!resource.has_binding_summary and
                    (resource.binding_summary.count != 0 or
                        resource.binding_summary.payload_bytes != 0 or
                        !zeroDigest(resource.binding_summary.digest))) or
                resource.allocation_set.abi_version !=
                    engine.leased_paged_kv_cache.allocation_set_abi or
                resource.allocation_set.count != expected_pages or
                resource.allocation_set.payload_bytes !=
                    @as(u64, @intCast(expected_pages)) * self.page_payload_bytes)
                return false;
            if ((expected_pages == 0) !=
                zeroDigest(resource.allocation_set.sha256))
                return false;

            const active = sequence < published_tokens[lane];
            const terminal_now = active and
                sequence + 1 == published_tokens[lane];
            if (resource.has_terminal_generation != terminal_now or
                (terminal_now and
                    resource.terminal_generation !=
                        expectedRootGeneration(sequence, lane)) or
                (!terminal_now and resource.terminal_generation != 0))
                return false;
            const expected_canonical = if (active)
                sequence == 0 or terminal_now
            else
                lifecycle == .terminal_retained;
            if (resource.has_canonical_after != expected_canonical or
                (expected_canonical == zeroDigest(
                    resource.canonical_after_sha256,
                )))
                return false;

            for (proposal.resources[0..lane]) |prior| {
                if (expected_pages != 0 and
                    (std.mem.eql(
                        u8,
                        &resource.binding_summary.digest,
                        &prior.binding_summary.digest,
                    ) or std.mem.eql(
                        u8,
                        &resource.allocation_set.sha256,
                        &prior.allocation_set.sha256,
                    )))
                    return false;
                if (!self.cohort_initialized) {
                    if (resource.coordinator_instance ==
                        prior.coordinator_instance or
                        resource.cache_instance == prior.cache_instance or
                        (resource.scope_index == prior.scope_index and
                            resource.scope_generation == prior.scope_generation))
                        return false;
                }
            }

            if (self.cohort_initialized) {
                if (resource.coordinator_instance !=
                    self.coordinator_instances[lane] or
                    resource.cache_instance != self.cache_instances[lane] or
                    resource.scope_index != self.scope_indices[lane] or
                    resource.scope_generation != self.scope_generations[lane])
                    return false;
                const previous_pages = expectedResourcePages(
                    self.policy,
                    sequence - 1,
                    lane,
                );
                if (expected_pages == previous_pages) {
                    if (!std.meta.eql(
                        resource.binding_summary,
                        self.last_binding_summaries[lane],
                    ) or !std.meta.eql(
                        resource.allocation_set,
                        self.last_allocation_sets[lane],
                    ))
                        return false;
                } else if (expected_pages != 0 and previous_pages != 0 and
                    (std.mem.eql(
                        u8,
                        &resource.binding_summary.digest,
                        &self.last_binding_summaries[lane].digest,
                    ) or std.mem.eql(
                        u8,
                        &resource.allocation_set.sha256,
                        &self.last_allocation_sets[lane].sha256,
                    )))
                    return false;
            }
            total_payload = std.math.add(
                u64,
                total_payload,
                resource.allocation_set.payload_bytes,
            ) catch return false;
        }
        if (total_payload != proposal.tree.current.kv_bytes) return false;

        for (0..width) |lane| {
            const active = sequence < published_tokens[lane];
            const lane_proposal = proposal.lanes[lane];
            const resource = proposal.resources[lane];
            if (!active) {
                if (!std.meta.eql(
                    lane_proposal,
                    engine.paged_lease_token_txn.LaneProposalV3{},
                )) return false;
                const last_root = self.last_roots[lane] orelse return false;
                if (!std.meta.eql(resource.root, last_root) or
                    !std.mem.eql(
                        u8,
                        &resource.kv_state_chain_after,
                        &self.last_state_chains[lane],
                    ) or
                    (resource.lifecycle == .terminal_retained and
                        !std.mem.eql(
                            u8,
                            &resource.canonical_after_sha256,
                            &self.terminal_canonical_sha256[lane],
                        )))
                    return false;
                continue;
            }
            const terminal_now = sequence + 1 == published_tokens[lane];
            const expected_token: u32 = if (terminal_now)
                eos_token
            else
                non_eos_token;
            const transition = lane_proposal.kv_transition;
            if (lane_proposal.lane_index != lane or
                lane_proposal.step_index != sequence or
                lane_proposal.prompt_len != prompt_len or
                lane_proposal.kv_after != prompt_len + sequence or
                lane_proposal.has_kv_transition != (sequence != 0) or
                lane_proposal.output_before != sequence or
                lane_proposal.output_after != sequence + 1 or
                !std.mem.eql(
                    u8,
                    &lane_proposal.output_sha256,
                    &expectedOutputSha256(lane, sequence + 1),
                ) or
                lane_proposal.sampling_calls_before != 0 or
                lane_proposal.sampling_calls_after != 0 or
                !std.mem.eql(
                    u64,
                    &lane_proposal.rng_before,
                    &lane_proposal.rng_after,
                ) or lane_proposal.token_id != expected_token or
                lane_proposal.terminal_reason !=
                    (if (terminal_now)
                        engine.leased_paged_kv_cache.TerminalReason.eos
                    else
                        null) or
                transition.abi_version !=
                    engine.paged_lease_token_txn.page_transition_abi or
                transition.kv_row_txn_abi !=
                    engine.paged_kv_cache.row_txn_abi or
                transition.page_map_root_abi !=
                    engine.paged_kv_cache.page_map_root_abi or
                transition.page_ref_abi !=
                    engine.paged_kv_cache.page_ref_abi or
                transition.cache_instance != resource.cache_instance or
                transition.root_after_len !=
                    prompt_len + sequence or
                transition.root_after_pages !=
                    pagesForPositions(prompt_len + sequence) or
                zeroDigest(transition.state_chain_after) or
                !rootMatchesTransitionAfter(resource.root, transition) or
                !std.mem.eql(
                    u8,
                    &resource.kv_state_chain_after,
                    &transition.state_chain_after,
                ))
                return false;
            if (sequence == 0) {
                const expected_chain = expectedInitialStateChain(
                    transition.initial_logical_kv_sha256,
                    resource.root,
                );
                if (lane_proposal.kv_before != prompt_len or
                    transition.row_txn_generation != 0 or
                    transition.root_before_len != prompt_len or
                    transition.root_before_pages !=
                        pagesForPositions(prompt_len) or
                    transition.root_before_generation !=
                        transition.root_after_generation or
                    !std.mem.eql(
                        u8,
                        &transition.root_before_ownership_sha256,
                        &transition.root_after_ownership_sha256,
                    ) or transition.logical_page != 0 or
                    transition.page_ownership_generation != 0 or
                    transition.installs_new_page or
                    zeroDigest(transition.initial_logical_kv_sha256) or
                    !zeroDigest(transition.row_payload_sha256) or
                    !std.mem.eql(
                        u8,
                        &transition.state_chain_before,
                        &transition.state_chain_after,
                    ) or !std.mem.eql(
                    u8,
                    &transition.state_chain_after,
                    &expected_chain,
                ) or !std.mem.eql(
                    u8,
                    &resource.canonical_after_sha256,
                    &transition.initial_logical_kv_sha256,
                ) or !std.mem.eql(
                    u64,
                    &lane_proposal.rng_before,
                    &expectedInitialRng(lane),
                ))
                    return false;
            } else {
                const previous_root = self.last_roots[lane] orelse return false;
                const row_position = prompt_len + sequence - 1;
                const installs_new_page = row_position %
                    engine.paged_kv_cache.page_positions == 0;
                const expected_chain = expectedAppendedStateChain(
                    self.last_state_chains[lane],
                    previous_root,
                    resource.root,
                    transition,
                );
                if (lane_proposal.kv_before != row_position or
                    transition.row_txn_generation == 0 or
                    transition.root_before_len !=
                        prompt_len + sequence - 1 or
                    transition.root_before_pages !=
                        pagesForPositions(row_position) or
                    transition.root_after_generation <=
                        transition.root_before_generation or
                    transition.logical_page != row_position /
                        engine.paged_kv_cache.page_positions or
                    transition.page_ownership_generation == 0 or
                    transition.installs_new_page != installs_new_page or
                    zeroDigest(transition.row_payload_sha256) or
                    !zeroDigest(transition.initial_logical_kv_sha256) or
                    !transitionBeforeMatchesRoot(transition, previous_root) or
                    !std.mem.eql(
                        u8,
                        &transition.state_chain_before,
                        &self.last_state_chains[lane],
                    ) or !std.mem.eql(
                    u8,
                    &transition.state_chain_after,
                    &expected_chain,
                ) or !std.mem.eql(
                    u64,
                    &lane_proposal.rng_before,
                    &self.last_rng[lane],
                ) or lane_proposal.sampling_calls_before !=
                    self.last_sampling_calls[lane] or
                    (installs_new_page == std.mem.eql(
                        u8,
                        &transition.root_before_ownership_sha256,
                        &transition.root_after_ownership_sha256,
                    )))
                    return false;
            }
        }
        return true;
    }

    fn validateTerminalSeal(
        self: *@This(),
        receipt: *const engine.paged_lease_token_txn.CommitReceiptV3,
        lane_index: usize,
        seal: engine.leased_paged_kv_cache.TerminalSealV3,
    ) bool {
        _ = self;
        const proposal = receipt.proposal;
        const resource = proposal.resources[lane_index];
        const lane = proposal.lanes[lane_index];
        return seal.abi_version ==
            engine.leased_paged_kv_cache.terminal_seal_v3_abi and
            seal.coordinator_instance == resource.coordinator_instance and
            seal.cache_instance == resource.cache_instance and
            seal.scope_index == resource.scope_index and
            seal.scope_generation == resource.scope_generation and
            seal.tree_identity_generation == proposal.tree.identity_generation and
            seal.tree_generation == proposal.tree.generation and
            seal.tree_structural_revision == proposal.tree.structural_revision and
            seal.tree_state_digest == proposal.tree.state_digest and
            std.meta.eql(seal.root, resource.root) and
            std.mem.eql(
                u8,
                &seal.logical_kv_sha256,
                &resource.canonical_after_sha256,
            ) and std.meta.eql(
            seal.bindings,
            resource.binding_summary,
        ) and
            std.meta.eql(seal.allocation_set, resource.allocation_set) and
            seal.transaction_sequence == proposal.transaction_sequence and
            seal.permit_generation == proposal.resource_permit_generation and
            seal.terminal_reason == .eos and seal.terminal_token == eos_token and
            std.mem.eql(u64, &seal.rng_after, &lane.rng_after) and
            seal.sampling_calls_after == lane.sampling_calls_after and
            std.mem.eql(u8, &seal.output_sha256, &lane.output_sha256) and
            std.mem.eql(
                u8,
                &seal.proposal_sha256,
                &receipt.proposal_sha256,
            ) and std.mem.eql(
            u8,
            &seal.commit_sha256,
            &receipt.commit_sha256,
        ) and seal.generation == resource.terminal_generation and std.mem.eql(
            u8,
            &seal.digest,
            &engine.leased_paged_kv_cache.terminalSealV3Digest(seal),
        );
    }

    fn prepare(
        context: *anyopaque,
        proposal: *const engine.paged_lease_token_txn.ProposalV3,
        ack: *engine.paged_lease_token_txn.PrepareAckV3,
    ) engine.paged_lease_token_txn.SinkPrepareError!void {
        const self = fromContext(context);
        if (self.pending or self.prepare_count >= expected_waves)
            return error.InvalidEvidence;
        if (!self.validateProposal(proposal.*)) {
            std.debug.print(
                "invalid proposal policy={s} sequence={d} active_nodes={d} expected_nodes={d} payload={d}\n",
                .{
                    self.policy.label(),
                    proposal.transaction_sequence,
                    proposal.tree.active_nodes,
                    expectedActiveNodes(
                        self.policy,
                        @intCast(proposal.transaction_sequence),
                    ),
                    proposal.tree.current.kv_bytes,
                },
            );
            return error.InvalidEvidence;
        }
        const digest = engine.paged_lease_token_txn.proposalSha256(proposal.*);
        ack.* = .{
            .proposal_sha256 = digest,
            .sink_epoch = 0x5032_4c45_4153_4503,
            .reservation_id = proposal.transaction_sequence + 1,
        };
        self.pending = true;
        self.pending_proposal_sha256 = digest;
        self.pending_ack = ack.*;
        self.prepare_count += 1;
    }

    fn commit(
        context: *anyopaque,
        receipt: *const engine.paged_lease_token_txn.CommitReceiptV3,
    ) void {
        const self = fromContext(context);
        if (!self.pending or self.commit_count >= expected_waves or
            !self.validateProposal(receipt.proposal))
        {
            self.valid = false;
            return;
        }
        const proposal_digest = engine.paged_lease_token_txn.proposalSha256(
            receipt.proposal,
        );
        const commit_digest = engine.paged_lease_token_txn.commitSha256(
            receipt.proposal_sha256,
            receipt.prepare_ack,
        );
        if (receipt.abi_version !=
            engine.paged_lease_token_txn.commit_receipt_abi or
            !std.mem.eql(
                u8,
                &proposal_digest,
                &receipt.proposal_sha256,
            ) or !std.mem.eql(
            u8,
            &self.pending_proposal_sha256,
            &receipt.proposal_sha256,
        ) or !std.meta.eql(self.pending_ack, receipt.prepare_ack) or
            !std.mem.eql(u8, &commit_digest, &receipt.commit_sha256))
            self.valid = false;

        var terminal_mask: u8 = 0;
        for (receipt.proposal.lanes, 0..) |lane, lane_index| {
            const active = receipt.proposal.live_mask &
                (@as(u8, 1) << @intCast(lane_index)) != 0;
            self.lane_transitions += @intFromBool(active);
            self.kv_transitions += @intFromBool(
                active and lane.has_kv_transition,
            );
            const terminal_now = active and lane.terminal_reason != null;
            if (terminal_now) terminal_mask |=
                @as(u8, 1) << @intCast(lane_index);
            const maybe_seal = receipt.terminal_seals[lane_index];
            if (terminal_now != (maybe_seal != null)) self.valid = false;
            if (maybe_seal) |seal| {
                self.terminal_seals += 1;
                if (!self.validateTerminalSeal(receipt, lane_index, seal))
                    self.valid = false;
            }
        }

        if (!self.cohort_initialized) {
            self.parent_receipt = receipt.proposal.parent_receipt;
            self.tree_key = receipt.proposal.tree.tree_key;
            self.tree_identity_generation =
                receipt.proposal.tree.identity_generation;
            for (receipt.proposal.resources, 0..) |resource, lane| {
                self.coordinator_instances[lane] =
                    resource.coordinator_instance;
                self.cache_instances[lane] = resource.cache_instance;
                self.scope_indices[lane] = resource.scope_index;
                self.scope_generations[lane] = resource.scope_generation;
            }
            self.cohort_initialized = true;
        }

        for (receipt.proposal.lanes, 0..) |lane, lane_index| {
            const active = receipt.proposal.live_mask &
                (@as(u8, 1) << @intCast(lane_index)) != 0;
            const resource = receipt.proposal.resources[lane_index];
            self.last_binding_summaries[lane_index] =
                resource.binding_summary;
            self.last_allocation_sets[lane_index] = resource.allocation_set;
            if (!active) continue;
            self.last_roots[lane_index] = resource.root;
            self.last_state_chains[lane_index] = resource.kv_state_chain_after;
            self.last_output_sha256[lane_index] = lane.output_sha256;
            self.last_rng[lane_index] = lane.rng_after;
            self.last_sampling_calls[lane_index] = lane.sampling_calls_after;
            if (lane.terminal_reason != null)
                self.terminal_canonical_sha256[lane_index] =
                    resource.canonical_after_sha256;
        }
        self.last_tree_generation = receipt.proposal.tree.generation;
        self.last_tree_structural_revision =
            receipt.proposal.tree.structural_revision;
        self.last_tree_payload_bytes = receipt.proposal.tree.current.kv_bytes;
        self.last_tree_active_nodes = receipt.proposal.tree.active_nodes;
        self.last_tree_state_digest = receipt.proposal.tree.state_digest;
        self.last_tree_token_integrity = receipt.proposal.tree.token_integrity;
        self.last_resource_permit_generation =
            receipt.proposal.resource_permit_generation;

        self.waves[self.commit_count] = .{
            .sequence = receipt.proposal.transaction_sequence,
            .live_mask = receipt.proposal.live_mask,
            .terminal_mask = terminal_mask,
            .live_lane_count = receipt.proposal.live_lane_count,
            .tree_payload_bytes = receipt.proposal.tree.current.kv_bytes,
            .active_nodes = receipt.proposal.tree.active_nodes,
            .proposal_sha256 = receipt.proposal_sha256,
            .commit_sha256 = receipt.commit_sha256,
        };
        self.head_sha256 = advanceHead(
            self.head_sha256,
            receipt.proposal_sha256,
            receipt.commit_sha256,
        );
        self.commit_count += 1;
        self.pending = false;
        self.pending_proposal_sha256 = [_]u8{0} ** 32;
        self.pending_ack = .{};
    }

    fn abort(
        context: *anyopaque,
        proposal: *const engine.paged_lease_token_txn.ProposalV3,
        ack: *const engine.paged_lease_token_txn.PrepareAckV3,
    ) void {
        const self = fromContext(context);
        if (!self.pending or !std.mem.eql(
            u8,
            &self.pending_proposal_sha256,
            &engine.paged_lease_token_txn.proposalSha256(proposal.*),
        ) or !std.meta.eql(self.pending_ack, ack.*))
            self.valid = false;
        self.abort_count += 1;
        self.pending = false;
        self.pending_proposal_sha256 = [_]u8{0} ** 32;
        self.pending_ack = .{};
    }
};

const AdmissionBSink = struct {
    expected_envelope: ?engine.decode_lane4.ResourceAdmissionEnvelope = null,
    expected_request_epoch: u64,
    page_payload_bytes: u64,
    prepare_count: usize = 0,
    commit_count: usize = 0,
    abort_count: usize = 0,
    valid: bool = true,
    pending: bool = false,
    pending_ack: engine.paged_lease_token_txn.PrepareAckV3 = .{},
    pending_proposal_sha256: [32]u8 = [_]u8{0} ** 32,
    receipt: ?engine.paged_lease_token_txn.CommitReceiptV3 = null,

    fn interface(self: *@This()) engine.paged_lease_token_txn.SinkV3 {
        return .{
            .context = self,
            .prepare = prepare,
            .commit = commit,
            .abort = abort,
        };
    }

    fn fromContext(context: *anyopaque) *@This() {
        return @ptrCast(@alignCast(context));
    }

    fn validateProposal(
        self: *@This(),
        proposal: engine.paged_lease_token_txn.ProposalV3,
    ) bool {
        const envelope = self.expected_envelope orelse return false;
        if (proposal.abi_version != engine.paged_lease_token_txn.abi or
            proposal.resource_bank_abi != core.resource_bank.abi or
            proposal.resource_lease_tree_abi != core.resource_bank.lease_tree_abi or
            proposal.resource_publication_fence_abi !=
                core.resource_bank.publication_fence_abi or
            proposal.leased_paged_kv_abi != engine.leased_paged_kv_cache.abi or
            proposal.paged_kv_abi != engine.paged_kv_cache.abi or
            proposal.page_transition_abi !=
                engine.paged_lease_token_txn.page_transition_abi or
            proposal.execution_abi != engine.decode_lane4.paged_lease_decode_abi or
            proposal.request_epoch != self.expected_request_epoch or
            proposal.transaction_sequence != 0 or
            proposal.resource_permit_generation != 1 or
            proposal.live_mask != 0b1111 or
            proposal.live_lane_count != width or
            !std.meta.eql(proposal.parent_receipt.claim, envelope.parent_claim) or
            proposal.parent_receipt.bank_epoch == 0 or
            proposal.parent_receipt.generation == 0 or
            proposal.parent_receipt.owner_key == 0 or
            proposal.parent_receipt.integrity == 0 or
            proposal.tree.abi_version !=
                engine.paged_lease_token_txn.tree_commitment_abi or
            !std.meta.eql(proposal.tree.ceiling, envelope.lease_tree_ceiling) or
            proposal.tree.current.kv_bytes != self.page_payload_bytes * 8 or
            proposal.tree.current.capsule_bytes != 0 or
            proposal.tree.current.activation_bytes != 0 or
            proposal.tree.current.partial_bytes != 0 or
            proposal.tree.current.logits_bytes != 0 or
            proposal.tree.current.output_journal_bytes != 0 or
            proposal.tree.current.staging_bytes != 0 or
            proposal.tree.current.device_bytes != 0 or
            proposal.tree.current.io_bytes != 0 or
            proposal.tree.current.queue_slots != 0 or
            proposal.tree.tree_key == 0 or
            proposal.tree.identity_generation == 0 or
            proposal.tree.generation == 0 or
            proposal.tree.structural_revision != 21 or
            proposal.tree.active_nodes != 12 or
            proposal.tree.state_digest == 0 or
            proposal.tree.token_integrity == 0)
            return false;

        const expected_output = engine.generate.tokenSequenceSha256(
            &[_]u32{eos_token},
        );
        var total_payload: u64 = 0;
        for (proposal.resources, 0..) |resource, lane| {
            const lane_proposal = proposal.lanes[lane];
            const transition = lane_proposal.kv_transition;
            if (resource.abi_version !=
                engine.paged_lease_token_txn.resource_commitment_abi or
                resource.lane_index != lane or
                resource.lifecycle != .live or
                resource.coordinator_instance == 0 or
                resource.cache_instance == 0 or
                resource.scope_index >= admission_lease_nodes or
                resource.scope_generation == 0 or
                resource.root.abi_version !=
                    engine.paged_kv_cache.page_map_root_abi or
                resource.root.cache_instance != resource.cache_instance or
                resource.root.generation != admission_b_prompt_len + 1 or
                resource.root.committed_len != admission_b_prompt_len or
                resource.root.committed_pages != 2 or
                zeroDigest(resource.root.ownership_sha256) or
                zeroDigest(resource.kv_state_chain_after) or
                !resource.has_canonical_after or
                zeroDigest(resource.canonical_after_sha256) or
                !resource.has_terminal_generation or
                resource.terminal_generation != admission_b_prompt_len + 1 or
                !resource.has_binding_summary or
                resource.binding_summary.count != 2 or
                resource.binding_summary.payload_bytes !=
                    self.page_payload_bytes * 2 or
                zeroDigest(resource.binding_summary.digest) or
                resource.allocation_set.abi_version !=
                    engine.leased_paged_kv_cache.allocation_set_abi or
                resource.allocation_set.count != 2 or
                resource.allocation_set.payload_bytes !=
                    self.page_payload_bytes * 2 or
                zeroDigest(resource.allocation_set.sha256) or
                lane_proposal.lane_index != lane or
                lane_proposal.step_index != 0 or
                lane_proposal.prompt_len != admission_b_prompt_len or
                lane_proposal.kv_before != admission_b_prompt_len or
                lane_proposal.kv_after != admission_b_prompt_len or
                lane_proposal.has_kv_transition or
                lane_proposal.output_before != 0 or
                lane_proposal.output_after != 1 or
                !std.mem.eql(u8, &lane_proposal.output_sha256, &expected_output) or
                !std.mem.eql(
                    u64,
                    &lane_proposal.rng_before,
                    &expectedAdmissionBRng(lane),
                ) or
                !std.mem.eql(
                    u64,
                    &lane_proposal.rng_before,
                    &lane_proposal.rng_after,
                ) or
                lane_proposal.sampling_calls_before != 0 or
                lane_proposal.sampling_calls_after != 0 or
                lane_proposal.token_id != eos_token or
                lane_proposal.terminal_reason != .eos or
                transition.abi_version !=
                    engine.paged_lease_token_txn.page_transition_abi or
                transition.kv_row_txn_abi !=
                    engine.paged_kv_cache.row_txn_abi or
                transition.page_map_root_abi !=
                    engine.paged_kv_cache.page_map_root_abi or
                transition.page_ref_abi != engine.paged_kv_cache.page_ref_abi or
                transition.cache_instance != resource.cache_instance or
                transition.row_txn_generation != 0 or
                transition.root_before_generation != resource.root.generation or
                transition.root_after_generation != resource.root.generation or
                transition.root_before_len != admission_b_prompt_len or
                transition.root_after_len != admission_b_prompt_len or
                transition.root_before_pages != 2 or
                transition.root_after_pages != 2 or
                !std.mem.eql(
                    u8,
                    &transition.root_before_ownership_sha256,
                    &resource.root.ownership_sha256,
                ) or
                !std.mem.eql(
                    u8,
                    &transition.root_after_ownership_sha256,
                    &resource.root.ownership_sha256,
                ) or
                transition.logical_page != 0 or
                transition.page_ownership_generation != 0 or
                transition.installs_new_page or
                zeroDigest(transition.initial_logical_kv_sha256) or
                !zeroDigest(transition.row_payload_sha256) or
                !std.mem.eql(
                    u8,
                    &transition.state_chain_before,
                    &transition.state_chain_after,
                ) or
                !std.mem.eql(
                    u8,
                    &transition.state_chain_after,
                    &resource.kv_state_chain_after,
                ) or
                !std.mem.eql(
                    u8,
                    &resource.kv_state_chain_after,
                    &expectedInitialStateChain(
                        transition.initial_logical_kv_sha256,
                        resource.root,
                    ),
                ) or
                !std.mem.eql(
                    u8,
                    &resource.canonical_after_sha256,
                    &transition.initial_logical_kv_sha256,
                ))
                return false;
            for (proposal.resources[0..lane]) |prior| {
                if (resource.coordinator_instance == prior.coordinator_instance or
                    resource.cache_instance == prior.cache_instance or
                    resource.scope_index == prior.scope_index or
                    std.mem.eql(
                        u8,
                        &resource.binding_summary.digest,
                        &prior.binding_summary.digest,
                    ) or
                    std.mem.eql(
                        u8,
                        &resource.allocation_set.sha256,
                        &prior.allocation_set.sha256,
                    ))
                    return false;
            }
            total_payload += resource.allocation_set.payload_bytes;
        }
        return total_payload == proposal.tree.current.kv_bytes;
    }

    fn validateSeal(
        receipt: *const engine.paged_lease_token_txn.CommitReceiptV3,
        lane: usize,
        seal: engine.leased_paged_kv_cache.TerminalSealV3,
    ) bool {
        const proposal = receipt.proposal;
        const resource = proposal.resources[lane];
        const transition = proposal.lanes[lane];
        return seal.abi_version ==
            engine.leased_paged_kv_cache.terminal_seal_v3_abi and
            seal.coordinator_instance == resource.coordinator_instance and
            seal.cache_instance == resource.cache_instance and
            seal.scope_index == resource.scope_index and
            seal.scope_generation == resource.scope_generation and
            seal.tree_identity_generation == proposal.tree.identity_generation and
            seal.tree_generation == proposal.tree.generation and
            seal.tree_structural_revision == proposal.tree.structural_revision and
            seal.tree_state_digest == proposal.tree.state_digest and
            std.meta.eql(seal.root, resource.root) and
            std.mem.eql(
                u8,
                &seal.logical_kv_sha256,
                &resource.canonical_after_sha256,
            ) and
            std.meta.eql(seal.bindings, resource.binding_summary) and
            std.meta.eql(seal.allocation_set, resource.allocation_set) and
            seal.transaction_sequence == 0 and
            seal.permit_generation == proposal.resource_permit_generation and
            seal.terminal_reason == .eos and
            seal.terminal_token == eos_token and
            std.mem.eql(u64, &seal.rng_after, &transition.rng_after) and
            seal.sampling_calls_after == 0 and
            std.mem.eql(u8, &seal.output_sha256, &transition.output_sha256) and
            std.mem.eql(u8, &seal.proposal_sha256, &receipt.proposal_sha256) and
            std.mem.eql(u8, &seal.commit_sha256, &receipt.commit_sha256) and
            seal.generation == resource.terminal_generation and
            std.mem.eql(
                u8,
                &seal.digest,
                &engine.leased_paged_kv_cache.terminalSealV3Digest(seal),
            );
    }

    fn prepare(
        context: *anyopaque,
        proposal: *const engine.paged_lease_token_txn.ProposalV3,
        ack: *engine.paged_lease_token_txn.PrepareAckV3,
    ) engine.paged_lease_token_txn.SinkPrepareError!void {
        const self = fromContext(context);
        if (self.pending or self.prepare_count != 0 or
            !self.validateProposal(proposal.*))
            return error.InvalidEvidence;
        const digest = engine.paged_lease_token_txn.proposalSha256(proposal.*);
        ack.* = .{
            .proposal_sha256 = digest,
            .sink_epoch = 0x5032_4c45_4144_4d42,
            .reservation_id = 1,
        };
        self.pending = true;
        self.pending_ack = ack.*;
        self.pending_proposal_sha256 = digest;
        self.prepare_count = 1;
    }

    fn commit(
        context: *anyopaque,
        receipt: *const engine.paged_lease_token_txn.CommitReceiptV3,
    ) void {
        const self = fromContext(context);
        if (!self.pending or self.commit_count != 0 or
            !self.validateProposal(receipt.proposal))
        {
            self.valid = false;
            return;
        }
        const proposal_digest = engine.paged_lease_token_txn.proposalSha256(
            receipt.proposal,
        );
        const commit_digest = engine.paged_lease_token_txn.commitSha256(
            receipt.proposal_sha256,
            receipt.prepare_ack,
        );
        if (receipt.abi_version !=
            engine.paged_lease_token_txn.commit_receipt_abi or
            !std.mem.eql(u8, &proposal_digest, &receipt.proposal_sha256) or
            !std.mem.eql(
                u8,
                &self.pending_proposal_sha256,
                &receipt.proposal_sha256,
            ) or
            !std.meta.eql(self.pending_ack, receipt.prepare_ack) or
            !std.mem.eql(u8, &commit_digest, &receipt.commit_sha256))
            self.valid = false;
        for (receipt.terminal_seals, 0..) |maybe_seal, lane| {
            const seal = maybe_seal orelse {
                self.valid = false;
                continue;
            };
            if (!validateSeal(receipt, lane, seal)) self.valid = false;
        }
        self.receipt = receipt.*;
        self.commit_count = 1;
        self.pending = false;
        self.pending_ack = .{};
        self.pending_proposal_sha256 = [_]u8{0} ** 32;
    }

    fn abort(
        context: *anyopaque,
        proposal: *const engine.paged_lease_token_txn.ProposalV3,
        ack: *const engine.paged_lease_token_txn.PrepareAckV3,
    ) void {
        const self = fromContext(context);
        if (!self.pending or
            !std.mem.eql(
                u8,
                &self.pending_proposal_sha256,
                &engine.paged_lease_token_txn.proposalSha256(proposal.*),
            ) or
            !std.meta.eql(self.pending_ack, ack.*))
            self.valid = false;
        self.abort_count += 1;
        self.pending = false;
        self.pending_ack = .{};
        self.pending_proposal_sha256 = [_]u8{0} ** 32;
    }
};

fn baseOptions(
    sink: *Sink,
    policy: Policy,
    head_mode: engine.decode_lane4.GreedyHeadMode,
    pair_down_mode: engine.decode_lane4.PairDownMode,
    request_epoch: u64,
) engine.decode_lane4.Options {
    return .{
        .num_threads = 4,
        .kv_cache_mode = .paged16_required,
        .paged_admission_mode = .lease_tree_required,
        .lease_reclaim_policy = policy.engineValue(),
        .kv_capacity_positions = capacity_positions,
        .greedy_head_mode = head_mode,
        .attention_mode = .serial,
        .pair_down_mode = pair_down_mode,
        .paged_lease_token_txn_publication = .{
            .request_epoch = request_epoch,
            .sink = sink.interface(),
        },
    };
}

fn deriveEnvelope(
    model: engine.loader.LoadedModel,
    requests: [width]engine.decode_lane4.Request,
    policy: Policy,
    head_mode: engine.decode_lane4.GreedyHeadMode,
    pair_down_mode: engine.decode_lane4.PairDownMode,
) !engine.decode_lane4.ResourceAdmissionEnvelope {
    const epoch = 0x5032_4c45_4153_0001;
    var placeholder: Sink = .{
        .policy = policy,
        .expected_request_epoch = epoch,
        .page_payload_bytes = 1,
    };
    return engine.decode_lane4.deriveResourceAdmissionEnvelope(
        model,
        requests,
        baseOptions(
            &placeholder,
            policy,
            head_mode,
            pair_down_mode,
            epoch,
        ),
    );
}

fn hashPageRoot(
    hash: *std.crypto.hash.sha2.Sha256,
    root: engine.paged_kv_cache.PageMapRootV1,
) void {
    hashU64(hash, root.abi_version);
    hashU64(hash, root.cache_instance);
    hashU64(hash, root.generation);
    hashU64(hash, root.committed_len);
    hashU64(hash, root.committed_pages);
    hash.update(&root.ownership_sha256);
}

fn expectedInitialStateChain(
    logical_kv_sha256: [32]u8,
    root: engine.paged_kv_cache.PageMapRootV1,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-paged-lease-token-kv-chain-seed-v3\x00");
    hash.update(&logical_kv_sha256);
    hashPageRoot(&hash, root);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn expectedAppendedStateChain(
    chain_before: [32]u8,
    root_before: engine.paged_kv_cache.PageMapRootV1,
    root_after: engine.paged_kv_cache.PageMapRootV1,
    transition: engine.paged_lease_token_txn.RootTransitionV3,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-paged-lease-token-kv-chain-append-v3\x00");
    hash.update(&chain_before);
    hashPageRoot(&hash, root_before);
    hashPageRoot(&hash, root_after);
    hashU64(&hash, transition.page_ref_abi);
    hashU64(&hash, transition.cache_instance);
    hashU64(&hash, transition.logical_page);
    hashU64(&hash, transition.page_ownership_generation);
    hashU64(&hash, transition.row_txn_generation);
    hash.update(&transition.row_payload_sha256);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn validateEnvelope(
    model: engine.loader.LoadedModel,
    envelope: engine.decode_lane4.ResourceAdmissionEnvelope,
) !u64 {
    const lane_ledger = try engine.paged_kv_cache.deriveCapacityLedger(
        model.config.num_layers,
        model.config.num_kv_heads * model.config.head_dim,
        capacity_positions,
    );
    const page_payload_bytes: u64 = @intCast(lane_ledger.page_payload_bytes);
    const expected_page_map_bytes: u64 = @intCast(
        lane_ledger.page_map_bytes * width,
    );
    const expected_binding_bytes: u64 = @intCast(
        try engine.leased_paged_kv_cache.bindingStorageBytes(
            lane_ledger.page_count_capacity,
        ) * width,
    );
    const expected_bounded_payload = page_payload_bytes * 43;
    const expected_lane_bounded_payload = [width]u64{
        page_payload_bytes * 9,
        page_payload_bytes * 10,
        page_payload_bytes * 11,
        page_payload_bytes * 13,
    };
    if (model.config.dim != 896 or model.config.hidden_dim != 4864 or
        model.config.num_layers != 24 or model.config.vocab_size != 151936 or
        model.config.num_heads != 14 or model.config.head_dim != 64 or
        model.config.num_kv_heads != 2 or page_payload_bytes != 393_216 or
        expected_page_map_bytes != 2_048 or
        expected_binding_bytes != 55_296 or
        envelope.paged_admission_mode != .lease_tree_required or
        envelope.logical_kv_capacity_bytes != 50_333_696 or
        envelope.page_map_bytes != expected_page_map_bytes or
        envelope.binding_storage_bytes != expected_binding_bytes or
        envelope.bounded_peak_payload_bytes != expected_bounded_payload or
        !std.meta.eql(
            envelope.lane_bounded_payload_bytes,
            expected_lane_bounded_payload,
        ) or
        envelope.lease_tree_ceiling.kv_bytes != expected_bounded_payload or
        !envelope.child_ceiling.isZero() or
        envelope.required_lease_roots != 1 or
        envelope.required_lease_nodes != 47 or
        envelope.parent_claim.capsule_bytes != expected_binding_bytes or
        envelope.parent_claim.kv_bytes != expected_page_map_bytes or
        envelope.parent_claim.activation_bytes != 170_112 or
        envelope.parent_claim.partial_bytes != 0 or
        envelope.parent_claim.logits_bytes != 2_430_992 or
        envelope.parent_claim.output_journal_bytes != 480 or
        envelope.parent_claim.staging_bytes != 49_408 or
        envelope.parent_claim.device_bytes != 0 or
        envelope.parent_claim.io_bytes != 0 or
        envelope.parent_claim.queue_slots != width or
        try envelope.parent_claim.hostBytes() != 2_708_336 or
        envelope.bounded_peak_claim.kv_bytes != 16_910_336 or
        try envelope.bounded_peak_claim.hostBytes() != 19_616_624)
        return error.InvalidEvidence;
    return page_payload_bytes;
}

fn deriveAdmissionBEnvelope(
    model: engine.loader.LoadedModel,
    requests: [width]engine.decode_lane4.Request,
    head_mode: engine.decode_lane4.GreedyHeadMode,
    pair_down_mode: engine.decode_lane4.PairDownMode,
) !engine.decode_lane4.ResourceAdmissionEnvelope {
    const epoch = 0x5032_4c45_4144_4d01;
    var placeholder: AdmissionBSink = .{
        .expected_request_epoch = epoch,
        .page_payload_bytes = 1,
    };
    return engine.decode_lane4.deriveResourceAdmissionEnvelope(
        model,
        requests,
        .{
            .num_threads = 4,
            .kv_cache_mode = .paged16_required,
            .paged_admission_mode = .lease_tree_required,
            .lease_reclaim_policy = .terminal_immediate,
            .kv_capacity_positions = capacity_positions,
            .greedy_head_mode = head_mode,
            .attention_mode = .serial,
            .pair_down_mode = pair_down_mode,
            .paged_lease_token_txn_publication = .{
                .request_epoch = epoch,
                .sink = placeholder.interface(),
            },
        },
    );
}

fn validateAdmissionBEnvelope(
    envelope: engine.decode_lane4.ResourceAdmissionEnvelope,
    page_payload_bytes: u64,
) !void {
    if (page_payload_bytes != 393_216 or
        envelope.paged_admission_mode != .lease_tree_required or
        envelope.logical_kv_capacity_bytes != 50_333_696 or
        envelope.page_map_bytes != 2_048 or
        envelope.binding_storage_bytes != 55_296 or
        envelope.bounded_peak_payload_bytes != page_payload_bytes * 12 or
        !std.meta.eql(
            envelope.lane_bounded_payload_bytes,
            [_]u64{page_payload_bytes * 3} ** width,
        ) or
        envelope.lease_tree_ceiling.kv_bytes != page_payload_bytes * 12 or
        !envelope.child_ceiling.isZero() or
        envelope.required_lease_roots != 1 or
        envelope.required_lease_nodes != 16 or
        envelope.parent_claim.capsule_bytes != 55_296 or
        envelope.parent_claim.kv_bytes != 2_048 or
        envelope.parent_claim.activation_bytes != 170_112 or
        envelope.parent_claim.partial_bytes != 0 or
        envelope.parent_claim.logits_bytes != 2_430_992 or
        envelope.parent_claim.output_journal_bytes != 32 or
        envelope.parent_claim.staging_bytes != 8_448 or
        envelope.parent_claim.device_bytes != 0 or
        envelope.parent_claim.io_bytes != 0 or
        envelope.parent_claim.queue_slots != width or
        try envelope.parent_claim.hostBytes() != 2_666_928 or
        envelope.bounded_peak_claim.kv_bytes !=
            2_048 + page_payload_bytes * 12 or
        try envelope.bounded_peak_claim.hostBytes() !=
            2_666_928 + page_payload_bytes * 12)
        return error.InvalidEvidence;
}

fn admissionSharedLimits(
    page_payload_bytes: u64,
) !core.resource_bank.Limits {
    if (page_payload_bytes != 393_216) return error.InvalidEvidence;
    return .{
        .host_bytes = 20_710_688,
        .capsule_bytes = 110_592,
        .kv_bytes = 15_339_520,
        .activation_bytes = 340_224,
        .partial_bytes = 0,
        .logits_bytes = 4_861_984,
        .output_journal_bytes = 512,
        .staging_bytes = 57_856,
        .device_bytes = 0,
        .io_bytes = 0,
        .queue_slots = 8,
    };
}

const Run = struct {
    result: engine.decode_lane4.Result,
    telemetry: engine.decode_lane4.Telemetry,
    resources: engine.generate.RequestResourceTelemetry,
    envelope: engine.decode_lane4.ResourceAdmissionEnvelope,
    snapshot: core.resource_bank.SnapshotV3,
    sink: Sink,
    duration_ns: u64,

    fn deinit(self: *Run) void {
        self.result.deinit();
    }
};

fn runPolicy(
    allocator: std.mem.Allocator,
    model: engine.loader.LoadedModel,
    requests: [width]engine.decode_lane4.Request,
    policy: Policy,
    expected_envelope: engine.decode_lane4.ResourceAdmissionEnvelope,
    page_payload_bytes: u64,
    head_mode: engine.decode_lane4.GreedyHeadMode,
    pair_down_mode: engine.decode_lane4.PairDownMode,
    request_epoch: u64,
) !Run {
    if (expected_envelope.required_lease_nodes > max_lease_nodes)
        return error.InvalidEvidence;
    var slots = [_]core.resource_bank.Slot{.{}} ** 1;
    var roots = [_]core.resource_bank.LeaseTreeRootSlot{.{}} ** 1;
    var nodes = [_]core.resource_bank.LeaseNodeSlot{.{}} ** max_lease_nodes;
    var bank = try core.resource_bank.Bank.initWithLeaseTree(
        &slots,
        &roots,
        nodes[0..expected_envelope.required_lease_nodes],
        try exactLimits(expected_envelope.bounded_peak_claim),
        request_epoch ^ 0x4241_4e4b_0000_0000,
    );
    return runPolicyOnBank(
        allocator,
        model,
        requests,
        policy,
        expected_envelope,
        page_payload_bytes,
        head_mode,
        pair_down_mode,
        request_epoch,
        &bank,
        null,
        null,
    );
}

fn runPolicyOnBank(
    allocator: std.mem.Allocator,
    model: engine.loader.LoadedModel,
    requests: [width]engine.decode_lane4.Request,
    policy: Policy,
    expected_envelope: engine.decode_lane4.ResourceAdmissionEnvelope,
    page_payload_bytes: u64,
    head_mode: engine.decode_lane4.GreedyHeadMode,
    pair_down_mode: engine.decode_lane4.PairDownMode,
    request_epoch: u64,
    bank: *core.resource_bank.Bank,
    wave_observer: ?engine.decode_lane4.PagedLeaseWaveObserver,
    admission_observer: ?engine.decode_lane4.PagedLeaseAdmissionObserver,
) !Run {
    var sink: Sink = .{
        .policy = policy,
        .expected_envelope = expected_envelope,
        .expected_request_epoch = request_epoch,
        .page_payload_bytes = page_payload_bytes,
        .allow_external_generation_gaps = wave_observer != null,
    };
    const options = baseOptions(
        &sink,
        policy,
        head_mode,
        pair_down_mode,
        request_epoch,
    );
    const envelope = try engine.decode_lane4.deriveResourceAdmissionEnvelope(
        model,
        requests,
        options,
    );
    if (!std.meta.eql(expected_envelope, envelope))
        return error.InvalidEvidence;
    var telemetry: engine.decode_lane4.Telemetry = .{};
    var resources: engine.generate.RequestResourceTelemetry = .{};
    var timer = try std.time.Timer.start();
    var result = try engine.decode_lane4.generate(
        allocator,
        model,
        requests,
        .{
            .num_threads = 4,
            .request_resource_bank = bank,
            .resource_telemetry = &resources,
            .kv_cache_mode = .paged16_required,
            .paged_admission_mode = .lease_tree_required,
            .lease_reclaim_policy = policy.engineValue(),
            .kv_capacity_positions = capacity_positions,
            .greedy_head_mode = head_mode,
            .attention_mode = .serial,
            .pair_down_mode = pair_down_mode,
            .paged_lease_token_txn_publication = .{
                .request_epoch = request_epoch,
                .sink = sink.interface(),
            },
            .paged_lease_wave_observer = wave_observer,
            .paged_lease_admission_observer = admission_observer,
            .telemetry = &telemetry,
        },
    );
    errdefer result.deinit();
    const duration_ns = timer.read();
    const snapshot = try bank.snapshotV3();
    return .{
        .result = result,
        .telemetry = telemetry,
        .resources = resources,
        .envelope = envelope,
        .snapshot = snapshot,
        .sink = sink,
        .duration_ns = duration_ns,
    };
}

const AdmissionGate = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    checkpoint: ?engine.decode_lane4.PagedLeaseWaveEvidenceV1 = null,
    release_requested: bool = false,
    worker_finished: bool = false,

    fn observer(self: *@This()) engine.decode_lane4.PagedLeaseWaveObserver {
        return .{
            .context = self,
            .observe = observe,
        };
    }

    fn fromContext(context: *anyopaque) *@This() {
        return @ptrCast(@alignCast(context));
    }

    fn observe(
        context: *anyopaque,
        evidence: *const engine.decode_lane4.PagedLeaseWaveEvidenceV1,
    ) void {
        if (evidence.transaction_sequence != 0) return;
        const self = fromContext(context);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.checkpoint != null)
            @panic("admission checkpoint observed twice");
        self.checkpoint = evidence.*;
        self.condition.broadcast();
        while (!self.release_requested)
            self.condition.wait(&self.mutex);
    }

    fn waitForCheckpoint(
        self: *@This(),
    ) !engine.decode_lane4.PagedLeaseWaveEvidenceV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.checkpoint == null and !self.worker_finished)
            self.condition.wait(&self.mutex);
        return self.checkpoint orelse error.WorkerExitedBeforeCheckpoint;
    }

    fn release(self: *@This()) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.release_requested = true;
        self.condition.broadcast();
    }

    fn noteWorkerFinished(self: *@This()) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.worker_finished = true;
        self.condition.broadcast();
    }
};

const AdmissionFailureCapture = struct {
    count: usize = 0,
    evidence: ?engine.decode_lane4.PagedLeaseAdmissionFailureV1 = null,

    fn observer(self: *@This()) engine.decode_lane4.PagedLeaseAdmissionObserver {
        return .{
            .context = self,
            .observe = observe,
        };
    }

    fn observe(
        context: *anyopaque,
        evidence: *const engine.decode_lane4.PagedLeaseAdmissionFailureV1,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.count != 0) @panic("admission failure observed twice");
        self.evidence = evidence.*;
        self.count = 1;
    }
};

const AdmissionAWorker = struct {
    allocator: std.mem.Allocator,
    model: engine.loader.LoadedModel,
    requests: [width]engine.decode_lane4.Request,
    policy: Policy,
    envelope: engine.decode_lane4.ResourceAdmissionEnvelope,
    page_payload_bytes: u64,
    head_mode: engine.decode_lane4.GreedyHeadMode,
    pair_down_mode: engine.decode_lane4.PairDownMode,
    request_epoch: u64,
    bank: *core.resource_bank.Bank,
    gate: *AdmissionGate,
    result: ?Run = null,
    failure: ?anyerror = null,

    fn run(self: *@This()) void {
        defer self.gate.noteWorkerFinished();
        self.result = runPolicyOnBank(
            self.allocator,
            self.model,
            self.requests,
            self.policy,
            self.envelope,
            self.page_payload_bytes,
            self.head_mode,
            self.pair_down_mode,
            self.request_epoch,
            self.bank,
            self.gate.observer(),
            null,
        ) catch |err| {
            self.failure = err;
            return;
        };
    }
};

const AdmissionBAttempt = struct {
    result: ?engine.decode_lane4.Result = null,
    failure: ?engine.generate.GenerateError = null,
    telemetry: engine.decode_lane4.Telemetry,
    resources: engine.generate.RequestResourceTelemetry,
    sink: AdmissionBSink,
    snapshot: core.resource_bank.SnapshotV3,
    duration_ns: u64,

    fn deinit(self: *@This()) void {
        if (self.result) |*result| result.deinit();
        self.result = null;
    }
};

fn runAdmissionB(
    allocator: std.mem.Allocator,
    model: engine.loader.LoadedModel,
    requests: [width]engine.decode_lane4.Request,
    envelope: engine.decode_lane4.ResourceAdmissionEnvelope,
    page_payload_bytes: u64,
    head_mode: engine.decode_lane4.GreedyHeadMode,
    pair_down_mode: engine.decode_lane4.PairDownMode,
    request_epoch: u64,
    bank: *core.resource_bank.Bank,
    admission_capture: *AdmissionFailureCapture,
) !AdmissionBAttempt {
    var sink: AdmissionBSink = .{
        .expected_envelope = envelope,
        .expected_request_epoch = request_epoch,
        .page_payload_bytes = page_payload_bytes,
    };
    var telemetry: engine.decode_lane4.Telemetry = .{};
    var resources: engine.generate.RequestResourceTelemetry = .{};
    var failure: ?engine.generate.GenerateError = null;
    var timer = try std.time.Timer.start();
    var result: ?engine.decode_lane4.Result = engine.decode_lane4.generate(
        allocator,
        model,
        requests,
        .{
            .num_threads = 4,
            .request_resource_bank = bank,
            .resource_telemetry = &resources,
            .kv_cache_mode = .paged16_required,
            .paged_admission_mode = .lease_tree_required,
            .lease_reclaim_policy = .terminal_immediate,
            .kv_capacity_positions = capacity_positions,
            .greedy_head_mode = head_mode,
            .attention_mode = .serial,
            .pair_down_mode = pair_down_mode,
            .paged_lease_token_txn_publication = .{
                .request_epoch = request_epoch,
                .sink = sink.interface(),
            },
            .paged_lease_admission_observer = admission_capture.observer(),
            .telemetry = &telemetry,
        },
    ) catch |err| blk: {
        failure = err;
        break :blk null;
    };
    errdefer if (result) |*value| value.deinit();
    const duration_ns = timer.read();
    return .{
        .result = result,
        .failure = failure,
        .telemetry = telemetry,
        .resources = resources,
        .sink = sink,
        .snapshot = try bank.snapshotV3(),
        .duration_ns = duration_ns,
    };
}

fn validateAdmissionCheckpoint(
    checkpoint: engine.decode_lane4.PagedLeaseWaveEvidenceV1,
    run: *const Run,
    policy: Policy,
    page_payload_bytes: u64,
) !void {
    const envelope = run.envelope;
    const parent_receipt = run.sink.parent_receipt orelse
        return error.InvalidEvidence;
    const published_wave = run.sink.waves[0];
    const reclaimed = policy == .immediate;
    const expected_pages: u64 = if (reclaimed) 24 else 32;
    const expected_payload = page_payload_bytes * expected_pages;
    const expected_nodes: u32 = if (reclaimed) 28 else 36;
    const expected_reclaimed_mask: u8 = if (reclaimed) 0b0001 else 0;
    if (checkpoint.abi_version !=
        engine.decode_lane4.paged_lease_wave_observer_abi or
        checkpoint.request_epoch != run.sink.expected_request_epoch or
        checkpoint.transaction_sequence != 0 or checkpoint.next_sequence != 1 or
        checkpoint.published_live_mask != 0b1111 or
        checkpoint.terminal_mask != 0b0001 or
        checkpoint.remaining_live_mask != 0b1110 or
        checkpoint.reclaimed_mask != expected_reclaimed_mask or
        checkpoint.reclaim_policy != policy.engineValue() or
        published_wave.sequence != checkpoint.transaction_sequence or
        published_wave.live_mask != checkpoint.published_live_mask or
        published_wave.terminal_mask != checkpoint.terminal_mask or
        published_wave.live_lane_count != width or
        !std.mem.eql(
            u8,
            &checkpoint.proposal_sha256,
            &published_wave.proposal_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.commit_sha256,
            &published_wave.commit_sha256,
        ) or
        checkpoint.tree.abi_version !=
            engine.paged_lease_token_txn.tree_commitment_abi or
        checkpoint.tree.tree_key != run.sink.tree_key or
        checkpoint.tree.identity_generation !=
            run.sink.tree_identity_generation or
        !std.meta.eql(checkpoint.tree.ceiling, envelope.lease_tree_ceiling) or
        checkpoint.tree.current.kv_bytes != expected_payload or
        checkpoint.tree.current.capsule_bytes != 0 or
        checkpoint.tree.active_nodes != expected_nodes or
        checkpoint.tree.state_digest == 0 or
        checkpoint.tree.token_integrity == 0 or
        checkpoint.bank.abi_version != core.resource_bank.snapshot_v3_abi or
        checkpoint.bank.bank_epoch != parent_receipt.bank_epoch or
        checkpoint.bank.active_reservations != 0 or
        checkpoint.bank.committed_receipts != 1 or
        checkpoint.bank.active_lease_trees != 1 or
        checkpoint.bank.active_lease_scopes != width or
        checkpoint.bank.active_lease_nodes != expected_nodes or
        checkpoint.bank.live_allocations != expected_nodes - width or
        checkpoint.bank.reserved_unmaterialized_allocations != 0 or
        checkpoint.bank.quiescing_allocations != 0 or
        checkpoint.bank.free_authorized_allocations != 0 or
        checkpoint.bank.used.capsule_bytes != envelope.parent_claim.capsule_bytes or
        checkpoint.bank.used.kv_bytes !=
            envelope.parent_claim.kv_bytes + expected_payload or
        checkpoint.bank.used.activation_bytes !=
            envelope.parent_claim.activation_bytes or
        checkpoint.bank.used.logits_bytes != envelope.parent_claim.logits_bytes or
        checkpoint.bank.used.output_journal_bytes !=
            envelope.parent_claim.output_journal_bytes or
        checkpoint.bank.used.staging_bytes != envelope.parent_claim.staging_bytes or
        checkpoint.bank.used.queue_slots != width or
        try checkpoint.bank.used.hostBytes() !=
            try envelope.parent_claim.hostBytes() + expected_payload or
        checkpoint.bank.rejected_capacity != 0 or
        checkpoint.bank.rejected_slots != 0 or
        checkpoint.bank.rejected_lease_capacity != 0 or
        checkpoint.bank.rejected_lease_nodes != 0)
        return error.InvalidEvidence;
}

fn validateAdmissionARun(
    run: *const Run,
    policy: Policy,
    page_payload_bytes: u64,
) !void {
    if (!run.sink.valid or run.sink.pending or
        run.sink.prepare_count != expected_waves or
        run.sink.commit_count != expected_waves or
        run.sink.abort_count != 0 or
        run.sink.lane_transitions != total_published_tokens or
        run.sink.kv_transitions != total_kv_transitions or
        run.sink.terminal_seals != width or
        run.telemetry.token_txn_commits != expected_waves or
        run.telemetry.token_txn_lane_commits != total_published_tokens or
        run.telemetry.token_txn_kv_row_commits != total_kv_transitions or
        run.telemetry.token_txn_aborts != 0 or
        run.telemetry.token_txn_sink_rejects != 0 or
        run.telemetry.paged_lease_terminal_lanes != width or
        run.telemetry.paged_lease_reclaimed_lanes !=
            (if (policy == .immediate) width else 0) or
        run.telemetry.paged_lease_reclaimed_payload_bytes !=
            (if (policy == .immediate) page_payload_bytes * 39 else 0) or
        run.snapshot.abi_version != core.resource_bank.snapshot_v3_abi or
        !run.snapshot.used.isZero() or run.snapshot.active_reservations != 0 or
        run.snapshot.committed_receipts != 0 or
        run.snapshot.active_lease_trees != 0 or
        run.snapshot.active_lease_scopes != 0 or
        run.snapshot.active_lease_nodes != 0 or
        run.snapshot.reserved_unmaterialized_allocations != 0 or
        run.snapshot.live_allocations != 0 or
        run.snapshot.quiescing_allocations != 0 or
        run.snapshot.free_authorized_allocations != 0 or
        !std.meta.eql(
            run.snapshot.limits,
            try admissionSharedLimits(page_payload_bytes),
        ) or
        run.snapshot.lease_root_pool_bytes !=
            2 * @sizeOf(core.resource_bank.LeaseTreeRootSlot) or
        run.snapshot.lease_node_pool_bytes !=
            admission_lease_nodes * @sizeOf(core.resource_bank.LeaseNodeSlot))
        return error.InvalidEvidence;
    for (0..width) |lane| {
        const tokens = run.result.tokens(lane);
        const state = run.telemetry.lane_states[lane];
        if (tokens.len != published_tokens[lane] or
            tokens[tokens.len - 1] != eos_token or
            !std.mem.allEqual(u32, tokens[0 .. tokens.len - 1], non_eos_token) or
            !state.complete or state.kv_positions != terminal_positions[lane] or
            state.published_tokens != published_tokens[lane] or
            state.sampling_calls != 0 or
            !std.mem.eql(u64, &state.rng_state, &expectedInitialRng(lane)) or
            !std.mem.eql(
                u8,
                &state.output_sha256,
                &engine.generate.tokenSequenceSha256(tokens),
            ))
            return error.InvalidEvidence;
    }
}

fn validateAdmissionBSuccess(
    attempt: *const AdmissionBAttempt,
    envelope: engine.decode_lane4.ResourceAdmissionEnvelope,
    page_payload_bytes: u64,
    expected_slot: u32,
) !void {
    const result = attempt.result orelse return error.InvalidEvidence;
    const receipt = attempt.sink.receipt orelse return error.InvalidEvidence;
    if (attempt.failure != null or !attempt.sink.valid or attempt.sink.pending or
        attempt.sink.prepare_count != 1 or attempt.sink.commit_count != 1 or
        attempt.sink.abort_count != 0 or
        receipt.proposal.parent_receipt.slot_index != expected_slot or
        !std.meta.eql(receipt.proposal.parent_receipt.claim, envelope.parent_claim) or
        attempt.telemetry.token_txn_commits != 1 or
        attempt.telemetry.token_txn_lane_commits != width or
        attempt.telemetry.token_txn_first_token_commits != 1 or
        attempt.telemetry.token_txn_kv_row_commits != 0 or
        attempt.telemetry.token_txn_aborts != 0 or
        attempt.telemetry.paged_lease_terminal_lanes != width or
        attempt.telemetry.paged_lease_reclaimed_lanes != width or
        attempt.telemetry.paged_lease_reclaimed_payload_bytes !=
            page_payload_bytes * 8 or
        attempt.telemetry.paged_lease_retained_payload_bytes != 0 or
        attempt.telemetry.paged_kv_resident_bytes != envelope.page_map_bytes or
        attempt.resources.capsule_bytes != envelope.parent_claim.capsule_bytes or
        attempt.resources.kv_bytes != envelope.parent_claim.kv_bytes or
        attempt.resources.activation_bytes != envelope.parent_claim.activation_bytes or
        attempt.resources.logits_bytes != envelope.parent_claim.logits_bytes or
        attempt.resources.output_journal_bytes !=
            envelope.parent_claim.output_journal_bytes or
        attempt.resources.staging_bytes != envelope.parent_claim.staging_bytes or
        attempt.resources.queue_slots != width)
        return error.InvalidEvidence;
    for (0..width) |lane| {
        const tokens = result.tokens(lane);
        const state = attempt.telemetry.lane_states[lane];
        if (tokens.len != 1 or tokens[0] != eos_token or !state.complete or
            state.kv_positions != admission_b_prompt_len or
            state.published_tokens != 1 or state.sampling_calls != 0 or
            !std.mem.eql(u64, &state.rng_state, &expectedAdmissionBRng(lane)) or
            !std.mem.eql(
                u8,
                &state.output_sha256,
                &engine.generate.tokenSequenceSha256(tokens),
            ) or
            !std.mem.eql(
                u8,
                &state.kv_sha256,
                &receipt.proposal.resources[lane].canonical_after_sha256,
            ))
            return error.InvalidEvidence;
    }
}

fn validateAdmissionBFailure(
    attempt: *const AdmissionBAttempt,
    capture: *const AdmissionFailureCapture,
    a_run: *const Run,
    a_envelope: engine.decode_lane4.ResourceAdmissionEnvelope,
    b_envelope: engine.decode_lane4.ResourceAdmissionEnvelope,
    page_payload_bytes: u64,
) !void {
    const a_parent_receipt = a_run.sink.parent_receipt orelse
        return error.InvalidEvidence;
    const attempt_failure = attempt.failure orelse return error.InvalidEvidence;
    if (attempt.result != null or
        attempt_failure != error.ResourceBudgetExceeded or
        attempt.sink.prepare_count != 0 or attempt.sink.commit_count != 0 or
        attempt.sink.abort_count != 0 or capture.count != 1)
        return error.InvalidEvidence;
    const evidence = capture.evidence orelse return error.InvalidEvidence;
    if (evidence.abi_version !=
        engine.decode_lane4.paged_lease_admission_observer_abi or
        evidence.request_epoch != attempt.sink.expected_request_epoch or
        evidence.transaction_sequence != 0 or evidence.failed_lane != 3 or
        evidence.active_mask != 0b1111 or
        evidence.failure != .capacity_exceeded or
        evidence.tree.abi_version !=
            engine.paged_lease_token_txn.tree_commitment_abi or
        evidence.tree.tree_key == 0 or
        evidence.tree.tree_key == a_run.sink.tree_key or
        evidence.tree.identity_generation == 0 or
        !std.meta.eql(evidence.tree.ceiling, b_envelope.lease_tree_ceiling) or
        evidence.tree.current.kv_bytes != page_payload_bytes * 7 or
        evidence.tree.active_nodes != 11 or
        evidence.tree.state_digest == 0 or evidence.tree.token_integrity == 0 or
        evidence.bank.bank_epoch != a_parent_receipt.bank_epoch or
        evidence.bank.used.capsule_bytes !=
            a_envelope.parent_claim.capsule_bytes +
                b_envelope.parent_claim.capsule_bytes or
        evidence.bank.used.kv_bytes != page_payload_bytes * 39 + 4_096 or
        evidence.bank.used.activation_bytes != 340_224 or
        evidence.bank.used.logits_bytes != 4_861_984 or
        evidence.bank.used.output_journal_bytes != 512 or
        evidence.bank.used.staging_bytes != 57_856 or
        evidence.bank.used.queue_slots != 8 or
        try evidence.bank.used.hostBytes() != 20_710_688 or
        evidence.bank.active_reservations != 0 or
        evidence.bank.committed_receipts != 2 or
        evidence.bank.active_lease_trees != 2 or
        evidence.bank.active_lease_scopes != 8 or
        evidence.bank.active_lease_nodes != 47 or
        evidence.bank.live_allocations != 39 or
        evidence.bank.reserved_unmaterialized_allocations != 0 or
        evidence.bank.quiescing_allocations != 0 or
        evidence.bank.free_authorized_allocations != 0 or
        evidence.bank.rejected_lease_capacity != 1 or
        evidence.bank.rejected_lease_nodes != 0)
        return error.InvalidEvidence;
    const expected_allocated = [_]usize{ 2, 2, 2, 1 };
    const expected_reusable = [_]usize{ 1, 1, 1, 0 };
    for (evidence.lanes, 0..) |lane, lane_index| {
        if (lane.root.committed_len != 16 or
            lane.root.committed_pages != 1 or
            lane.allocation.allocated_pages != expected_allocated[lane_index] or
            lane.allocation.committed_pages != 1 or
            lane.allocation.provisional_pages != 0 or
            lane.allocation.reusable_pages != expected_reusable[lane_index] or
            lane.lifecycle != .live)
            return error.InvalidEvidence;
    }
    if (attempt.snapshot.used.kv_bytes !=
        a_envelope.parent_claim.kv_bytes + page_payload_bytes * 32 or
        attempt.snapshot.committed_receipts != 1 or
        attempt.snapshot.active_lease_trees != 1 or
        attempt.snapshot.active_lease_scopes != width or
        attempt.snapshot.active_lease_nodes != 36 or
        attempt.snapshot.live_allocations != 32 or
        attempt.snapshot.rejected_lease_capacity != 1 or
        attempt.snapshot.rejected_lease_nodes != 0)
        return error.InvalidEvidence;
}

fn validateAdmissionBEqual(
    candidate: *const AdmissionBAttempt,
    reference: *const AdmissionBAttempt,
) !void {
    const candidate_result = candidate.result orelse return error.StateMismatch;
    const reference_result = reference.result orelse return error.StateMismatch;
    if (!std.meta.eql(candidate.telemetry.lane_states, reference.telemetry.lane_states))
        return error.StateMismatch;
    for (0..width) |lane| if (!std.mem.eql(
        u32,
        candidate_result.tokens(lane),
        reference_result.tokens(lane),
    )) return error.StateMismatch;
}

const AdmissionArm = struct {
    policy: Policy,
    checkpoint: engine.decode_lane4.PagedLeaseWaveEvidenceV1,
    failure_evidence: ?engine.decode_lane4.PagedLeaseAdmissionFailureV1,
    a: Run,
    b_attempt: AdmissionBAttempt,
    b_reference: AdmissionBAttempt,
    final_snapshot: core.resource_bank.SnapshotV3,

    fn deinit(self: *@This()) void {
        self.a.deinit();
        self.b_attempt.deinit();
        self.b_reference.deinit();
    }
};

fn runAdmissionArm(
    allocator: std.mem.Allocator,
    model: engine.loader.LoadedModel,
    a_requests: [width]engine.decode_lane4.Request,
    b_requests: [width]engine.decode_lane4.Request,
    policy: Policy,
    a_envelope: engine.decode_lane4.ResourceAdmissionEnvelope,
    b_envelope: engine.decode_lane4.ResourceAdmissionEnvelope,
    page_payload_bytes: u64,
    head_mode: engine.decode_lane4.GreedyHeadMode,
    pair_down_mode: engine.decode_lane4.PairDownMode,
    epoch_base: u64,
) !AdmissionArm {
    var slots = [_]core.resource_bank.Slot{.{}} ** 2;
    var roots = [_]core.resource_bank.LeaseTreeRootSlot{.{}} ** 2;
    var nodes = [_]core.resource_bank.LeaseNodeSlot{.{}} ** admission_lease_nodes;
    var bank = try core.resource_bank.Bank.initWithLeaseTree(
        &slots,
        &roots,
        &nodes,
        try admissionSharedLimits(page_payload_bytes),
        epoch_base ^ 0x4241_4e4b_0000_0000,
    );
    var gate: AdmissionGate = .{};
    var worker: AdmissionAWorker = .{
        .allocator = allocator,
        .model = model,
        .requests = a_requests,
        .policy = policy,
        .envelope = a_envelope,
        .page_payload_bytes = page_payload_bytes,
        .head_mode = head_mode,
        .pair_down_mode = pair_down_mode,
        .request_epoch = epoch_base + 1,
        .bank = &bank,
        .gate = &gate,
    };
    var thread = try std.Thread.spawn(.{}, AdmissionAWorker.run, .{&worker});
    var joined = false;
    var took_worker_result = false;
    defer {
        if (!joined) {
            gate.release();
            thread.join();
        }
        if (!took_worker_result) if (worker.result) |*run| run.deinit();
    }

    const checkpoint = try gate.waitForCheckpoint();
    var failure_capture: AdmissionFailureCapture = .{};
    var b_attempt = try runAdmissionB(
        allocator,
        model,
        b_requests,
        b_envelope,
        page_payload_bytes,
        head_mode,
        pair_down_mode,
        epoch_base + 2,
        &bank,
        &failure_capture,
    );
    errdefer b_attempt.deinit();

    gate.release();
    thread.join();
    joined = true;
    if (worker.failure) |err| return err;
    var a = worker.result orelse return error.WorkerExitedWithoutResult;
    worker.result = null;
    took_worker_result = true;
    errdefer a.deinit();

    var reference_capture: AdmissionFailureCapture = .{};
    var b_reference = try runAdmissionB(
        allocator,
        model,
        b_requests,
        b_envelope,
        page_payload_bytes,
        head_mode,
        pair_down_mode,
        epoch_base + 3,
        &bank,
        &reference_capture,
    );
    errdefer b_reference.deinit();
    const final_snapshot = try bank.snapshotV3();

    try validateAdmissionCheckpoint(
        checkpoint,
        &a,
        policy,
        page_payload_bytes,
    );
    try validateAdmissionARun(&a, policy, page_payload_bytes);
    try validateAdmissionBSuccess(
        &b_reference,
        b_envelope,
        page_payload_bytes,
        0,
    );
    if (reference_capture.count != 0) return error.InvalidEvidence;
    if (policy == .retain) {
        try validateAdmissionBFailure(
            &b_attempt,
            &failure_capture,
            &a,
            a_envelope,
            b_envelope,
            page_payload_bytes,
        );
    } else {
        if (failure_capture.count != 0) return error.InvalidEvidence;
        try validateAdmissionBSuccess(
            &b_attempt,
            b_envelope,
            page_payload_bytes,
            1,
        );
        try validateAdmissionBEqual(&b_attempt, &b_reference);
    }
    if (!final_snapshot.used.isZero() or
        final_snapshot.active_reservations != 0 or
        final_snapshot.committed_receipts != 0 or
        final_snapshot.active_lease_trees != 0 or
        final_snapshot.active_lease_scopes != 0 or
        final_snapshot.active_lease_nodes != 0 or
        final_snapshot.reserved_unmaterialized_allocations != 0 or
        final_snapshot.live_allocations != 0 or
        final_snapshot.quiescing_allocations != 0 or
        final_snapshot.free_authorized_allocations != 0)
        return error.InvalidEvidence;

    return .{
        .policy = policy,
        .checkpoint = checkpoint,
        .failure_evidence = failure_capture.evidence,
        .a = a,
        .b_attempt = b_attempt,
        .b_reference = b_reference,
        .final_snapshot = final_snapshot,
    };
}

fn rate(duration_ns: u64) !f64 {
    if (duration_ns == 0) return error.InvalidTiming;
    return @as(f64, @floatFromInt(total_published_tokens)) *
        @as(f64, std.time.ns_per_s) /
        @as(f64, @floatFromInt(duration_ns));
}

fn finalPublicationIdentityMatches(
    sink: *const Sink,
    telemetry: engine.decode_lane4.Telemetry,
    resources: engine.generate.RequestResourceTelemetry,
) bool {
    const receipt = sink.parent_receipt orelse return false;
    return sink.cohort_initialized and
        telemetry.token_txn_request_epoch == sink.expected_request_epoch and
        telemetry.admitted_cohorts == 1 and telemetry.cohort_width == width and
        telemetry.thread_participants == 4 and
        resources.owner_key == receipt.owner_key and
        resources.bank_epoch == receipt.bank_epoch and
        resources.receipt_slot_index == receipt.slot_index and
        resources.receipt_generation == receipt.generation and
        resources.receipt_integrity == receipt.integrity;
}

fn validateCompletedRun(
    run: *const Run,
    policy: Policy,
    page_payload_bytes: u64,
) !void {
    const terminal_payload = page_payload_bytes * 39;
    const peak_pages: u64 = if (policy == .retain) 39 else 32;
    const peak_payload = page_payload_bytes * peak_pages;
    const actual_peak_kv = run.envelope.page_map_bytes + peak_payload;
    const actual_peak_host = try run.envelope.parent_claim.hostBytes() +
        peak_payload;
    const expected_resident = run.envelope.page_map_bytes +
        (if (policy == .retain) terminal_payload else 0);
    if (run.telemetry.abi_version != engine.decode_lane4.abi or
        run.telemetry.publication_mode !=
            .paged_lease_token_txn_required or
        run.telemetry.paged_admission_mode != .lease_tree_required or
        run.telemetry.lease_reclaim_policy != policy.engineValue() or
        run.telemetry.kv_cache_mode != .paged16_required or
        run.telemetry.kv_capacity_positions != capacity_positions or
        run.telemetry.paged_lease_decode_abi_version !=
            engine.decode_lane4.paged_lease_decode_abi or
        run.telemetry.paged_lease_token_txn_abi_version !=
            engine.paged_lease_token_txn.abi or
        run.telemetry.paged_lease_token_txn_sink_abi_version !=
            engine.paged_lease_token_txn.sink_abi or
        run.telemetry.token_txn_commits != expected_waves or
        run.telemetry.token_txn_lane_commits != total_published_tokens or
        run.telemetry.token_txn_first_token_commits != 1 or
        run.telemetry.token_txn_kv_row_commits != total_kv_transitions or
        run.telemetry.token_txn_aborts != 0 or
        run.telemetry.token_txn_sink_rejects != 0 or
        run.telemetry.token_txn_last_sequence != expected_waves - 1 or
        run.telemetry.paged_root_commits != total_kv_transitions or
        run.telemetry.paged_lease_terminal_lanes != width or
        !finalPublicationIdentityMatches(
            &run.sink,
            run.telemetry,
            run.resources,
        ) or
        run.telemetry.paged_lease_peak_payload_bytes != peak_payload or
        run.telemetry.paged_lease_binding_storage_bytes !=
            run.envelope.binding_storage_bytes or
        run.telemetry.paged_lease_required_roots != 1 or
        run.telemetry.paged_lease_required_nodes != 47 or
        run.telemetry.paged_kv_capacity_bytes !=
            run.envelope.logical_kv_capacity_bytes or
        run.telemetry.paged_kv_logical_capacity_bytes !=
            run.envelope.logical_kv_capacity_bytes or
        run.telemetry.paged_kv_page_map_commitment_bytes !=
            run.envelope.page_map_bytes or
        run.telemetry.paged_kv_resident_bytes != expected_resident or
        !run.sink.valid or run.sink.pending or
        run.sink.prepare_count != expected_waves or
        run.sink.commit_count != expected_waves or run.sink.abort_count != 0 or
        run.sink.lane_transitions != total_published_tokens or
        run.sink.kv_transitions != total_kv_transitions or
        run.sink.terminal_seals != width or zeroDigest(run.sink.head_sha256) or
        run.snapshot.abi_version != core.resource_bank.snapshot_v3_abi or
        !run.snapshot.used.isZero() or run.snapshot.active_reservations != 0 or
        run.snapshot.committed_receipts != 0 or
        run.snapshot.active_child_leases != 0 or
        run.snapshot.active_lease_trees != 0 or
        run.snapshot.active_lease_scopes != 0 or
        run.snapshot.active_lease_nodes != 0 or
        run.snapshot.reserved_unmaterialized_allocations != 0 or
        run.snapshot.live_allocations != 0 or
        run.snapshot.quiescing_allocations != 0 or
        run.snapshot.free_authorized_allocations != 0 or
        !std.meta.eql(
            run.snapshot.limits,
            try exactLimits(run.envelope.bounded_peak_claim),
        ) or run.snapshot.peak.kv_bytes != actual_peak_kv or
        run.snapshot.peak_host_bytes != actual_peak_host or
        run.snapshot.lease_root_pool_bytes !=
            @sizeOf(core.resource_bank.LeaseTreeRootSlot) or
        run.snapshot.lease_node_pool_bytes !=
            47 * @sizeOf(core.resource_bank.LeaseNodeSlot) or
        run.snapshot.lease_metadata_bytes !=
            @sizeOf(core.resource_bank.LeaseTreeRootSlot) +
                47 * @sizeOf(core.resource_bank.LeaseNodeSlot) or
        run.snapshot.successful_reservations != 1 or
        run.snapshot.successful_commits != 1 or
        run.snapshot.cancellations != 0 or
        run.snapshot.child_opens != 0 or run.snapshot.child_grows != 0 or
        run.snapshot.child_shrinks != 0 or run.snapshot.child_closes != 0 or
        run.snapshot.rejected_child_capacity != 0 or
        run.snapshot.lease_tree_opens != 1 or
        run.snapshot.lease_scope_opens != width or
        run.snapshot.lease_allocation_reserves != 39 or
        run.snapshot.lease_allocation_materializations != 39 or
        run.snapshot.lease_allocation_aborts != 0 or
        run.snapshot.lease_reclaim_prepares != width or
        run.snapshot.lease_reclaim_authorizations != width or
        run.snapshot.lease_reclaim_cancels != 0 or
        run.snapshot.lease_reclaim_commits != width or
        run.snapshot.lease_tree_closes != 1 or run.snapshot.releases != 1 or
        run.snapshot.rejected_capacity != 0 or
        run.snapshot.rejected_slots != 0 or
        run.snapshot.rejected_lease_capacity != 0 or
        run.snapshot.rejected_lease_nodes != 0 or
        run.resources.host_limit_bytes !=
            try run.envelope.bounded_peak_claim.hostBytes() or
        run.resources.host_claim_bytes !=
            try run.envelope.parent_claim.hostBytes() or
        run.resources.capsule_bytes != run.envelope.parent_claim.capsule_bytes or
        run.resources.kv_bytes != run.envelope.parent_claim.kv_bytes or
        run.resources.activation_bytes !=
            run.envelope.parent_claim.activation_bytes or
        run.resources.partial_bytes != run.envelope.parent_claim.partial_bytes or
        run.resources.logits_bytes != run.envelope.parent_claim.logits_bytes or
        run.resources.output_journal_bytes !=
            run.envelope.parent_claim.output_journal_bytes or
        run.resources.staging_bytes != run.envelope.parent_claim.staging_bytes or
        run.resources.device_bytes != run.envelope.parent_claim.device_bytes or
        run.resources.io_bytes != run.envelope.parent_claim.io_bytes or
        run.resources.queue_slots != width or
        run.resources.peak_host_bytes != actual_peak_host or
        run.resources.reservations != 1 or run.resources.commits != 1 or
        run.resources.cancellations != 0 or run.resources.releases != 1 or
        run.resources.capacity_rejects != 0 or
        run.resources.slot_rejects != 0 or
        run.resources.active_reservations != 0 or
        run.resources.committed_receipts != 0 or
        run.resources.active_child_leases != 0 or
        run.resources.child_lease_abi_version != 0 or
        run.resources.child_key != 0 or run.resources.child_generation != 0 or
        run.resources.child_integrity != 0 or
        run.resources.child_ceiling_kv_bytes != 0 or
        run.resources.child_current_kv_bytes != 0 or
        run.resources.logical_kv_capacity_bytes != 0 or
        run.resources.child_opens != 0 or run.resources.child_grows != 0 or
        run.resources.child_shrinks != 0 or run.resources.child_closes != 0 or
        run.resources.child_capacity_rejects != 0 or
        run.resources.derive_rejects != 0 or
        run.resources.release_failures != 0)
        return error.InvalidEvidence;

    if (policy == .retain) {
        if (run.telemetry.paged_lease_reclaimed_lanes != 0 or
            run.telemetry.paged_lease_reclaimed_payload_bytes != 0 or
            run.telemetry.paged_lease_retained_payload_bytes != terminal_payload or
            run.telemetry.paged_kv_allocated_pages != 39 or
            run.telemetry.paged_kv_committed_pages != 39 or
            run.telemetry.paged_kv_reusable_pages != 0)
            return error.InvalidEvidence;
    } else if (run.telemetry.paged_lease_reclaimed_lanes != width or
        run.telemetry.paged_lease_reclaimed_payload_bytes != terminal_payload or
        run.telemetry.paged_lease_retained_payload_bytes != 0 or
        run.telemetry.paged_kv_allocated_pages != 0 or
        run.telemetry.paged_kv_committed_pages != 0 or
        run.telemetry.paged_kv_reusable_pages != 0)
        return error.InvalidEvidence;

    for (0..width) |lane| {
        const tokens = run.result.tokens(lane);
        const state = run.telemetry.lane_states[lane];
        if (tokens.len != published_tokens[lane] or
            tokens[tokens.len - 1] != eos_token or
            !std.mem.allEqual(u32, tokens[0 .. tokens.len - 1], non_eos_token) or
            !state.complete or
            state.abi_version != engine.generate.generation_state_abi or
            state.rng_abi != engine.generate.generation_rng_abi or
            state.kv_positions != terminal_positions[lane] or
            state.published_tokens != published_tokens[lane] or
            state.sampling_calls != run.sink.last_sampling_calls[lane] or
            !std.mem.eql(
                u8,
                &state.kv_sha256,
                &run.sink.terminal_canonical_sha256[lane],
            ) or !std.mem.eql(
            u8,
            &state.output_sha256,
            &run.sink.last_output_sha256[lane],
        ) or !std.mem.eql(
            u64,
            &state.rng_state,
            &run.sink.last_rng[lane],
        ) or !std.mem.eql(
            u64,
            &state.rng_state,
            &expectedInitialRng(lane),
        ) or
            !std.mem.eql(
                u8,
                &state.output_sha256,
                &engine.generate.tokenSequenceSha256(tokens),
            ))
            return error.InvalidEvidence;
    }
}

fn validateEqual(retain: *const Run, immediate: *const Run) !void {
    if (!std.meta.eql(retain.envelope, immediate.envelope) or
        !std.meta.eql(
            retain.telemetry.lane_states,
            immediate.telemetry.lane_states,
        ) or retain.telemetry.token_graphs != immediate.telemetry.token_graphs or
        retain.telemetry.layer_m4_graphs != immediate.telemetry.layer_m4_graphs or
        retain.telemetry.projection_m4_dispatches !=
            immediate.telemetry.projection_m4_dispatches or
        retain.telemetry.lm_head_m4_dispatches !=
            immediate.telemetry.lm_head_m4_dispatches)
        return error.StateMismatch;
    for (0..width) |lane|
        if (!std.mem.eql(
            u32,
            retain.result.tokens(lane),
            immediate.result.tokens(lane),
        )) return error.StateMismatch;
}

fn writeRun(writer: anytype, run: *const Run, policy: Policy) !void {
    const head = std.fmt.bytesToHex(run.sink.head_sha256, .lower);
    try writer.print(
        "\"{s}\":{{\"policy\":\"{s}\",\"generate_call_ns\":{d},\"generate_call_published_tokens_per_second\":{d:.6},\"parent_host_bytes\":{d},\"bounded_peak_host_bytes\":{d},\"logical_kv_capacity_bytes\":{d},\"page_map_bytes\":{d},\"binding_storage_bytes\":{d},\"lease_ceiling_payload_bytes\":{d},\"bank_peak_kv_bytes\":{d},\"bank_peak_host_bytes\":{d},\"bank_final_used_zero\":true,\"lease_metadata_bytes\":{d},\"prepare_count\":{d},\"commit_count\":{d},\"lane_transitions\":{d},\"kv_transitions\":{d},\"terminal_seals\":{d},\"telemetry_terminal_reclaims\":{d},\"telemetry_reclaimed_payload_bytes\":{d},\"journal_head_sha256\":\"{s}\",\"waves\":[",
        .{
            if (policy == .retain) "retain" else "immediate",
            policy.label(),
            run.duration_ns,
            try rate(run.duration_ns),
            try run.envelope.parent_claim.hostBytes(),
            try run.envelope.bounded_peak_claim.hostBytes(),
            run.envelope.logical_kv_capacity_bytes,
            run.envelope.page_map_bytes,
            run.envelope.binding_storage_bytes,
            run.envelope.lease_tree_ceiling.kv_bytes,
            run.snapshot.peak.kv_bytes,
            run.snapshot.peak_host_bytes,
            run.snapshot.lease_metadata_bytes,
            run.sink.prepare_count,
            run.sink.commit_count,
            run.sink.lane_transitions,
            run.sink.kv_transitions,
            run.sink.terminal_seals,
            run.telemetry.paged_lease_reclaimed_lanes,
            run.telemetry.paged_lease_reclaimed_payload_bytes,
            &head,
        },
    );
    for (run.sink.waves[0..run.sink.commit_count], 0..) |wave, index| {
        if (index != 0) try writer.writeAll(",");
        const proposal = std.fmt.bytesToHex(wave.proposal_sha256, .lower);
        const commit = std.fmt.bytesToHex(wave.commit_sha256, .lower);
        try writer.print(
            "{{\"sequence\":{d},\"live_mask\":{d},\"terminal_mask\":{d},\"live_lanes\":{d},\"tree_payload_bytes\":{d},\"active_nodes\":{d},\"proposal_sha256\":\"{s}\",\"commit_sha256\":\"{s}\"}}",
            .{
                wave.sequence,
                wave.live_mask,
                wave.terminal_mask,
                wave.live_lane_count,
                wave.tree_payload_bytes,
                wave.active_nodes,
                &proposal,
                &commit,
            },
        );
    }
    try writer.writeAll("]}");
}

fn writeLaneStates(writer: anytype, run: *const Run) !void {
    try writer.writeAll("\"lane_states\":[");
    for (run.telemetry.lane_states, 0..) |state, lane| {
        if (lane != 0) try writer.writeAll(",");
        const kv_hex = std.fmt.bytesToHex(state.kv_sha256, .lower);
        const output_hex = std.fmt.bytesToHex(state.output_sha256, .lower);
        try writer.print(
            "{{\"lane\":{d},\"published_tokens\":{d},\"kv_positions\":{d},\"sampling_calls\":{d},\"kv_sha256\":\"{s}\",\"output_sha256\":\"{s}\",\"rng_state\":[\"{x:0>16}\",\"{x:0>16}\",\"{x:0>16}\",\"{x:0>16}\"]}}",
            .{
                lane,
                state.published_tokens,
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

fn writeAdmissionBStates(
    writer: anytype,
    attempt: *const AdmissionBAttempt,
) !void {
    try writer.writeAll("[");
    for (attempt.telemetry.lane_states, 0..) |state, lane| {
        if (lane != 0) try writer.writeAll(",");
        const kv_hex = std.fmt.bytesToHex(state.kv_sha256, .lower);
        const output_hex = std.fmt.bytesToHex(state.output_sha256, .lower);
        try writer.print(
            "{{\"lane\":{d},\"published_tokens\":{d},\"kv_positions\":{d},\"sampling_calls\":{d},\"kv_sha256\":\"{s}\",\"output_sha256\":\"{s}\",\"rng_state\":[\"{x:0>16}\",\"{x:0>16}\",\"{x:0>16}\",\"{x:0>16}\"]}}",
            .{
                lane,
                state.published_tokens,
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

fn writeAdmissionArm(
    writer: anytype,
    arm: *const AdmissionArm,
) !void {
    const policy_key = if (arm.policy == .retain) "retain" else "reclaim";
    const checkpoint_proposal = std.fmt.bytesToHex(
        arm.checkpoint.proposal_sha256,
        .lower,
    );
    const checkpoint_commit = std.fmt.bytesToHex(
        arm.checkpoint.commit_sha256,
        .lower,
    );
    const a_head = std.fmt.bytesToHex(arm.a.sink.head_sha256, .lower);
    const b_reference_receipt = arm.b_reference.sink.receipt orelse
        return error.InvalidEvidence;
    const b_reference_commit = std.fmt.bytesToHex(
        b_reference_receipt.commit_sha256,
        .lower,
    );
    const failure_name = if (arm.b_attempt.failure) |failure|
        @errorName(failure)
    else
        "none";
    try writer.print(
        "\"{s}\":{{\"policy\":\"{s}\",\"causal_b_completed_prompts\":{d},\"causal_b_published_first_tokens\":{d},\"a_generate_ns\":{d},\"b_attempt_ns\":{d},\"b_reference_ns\":{d},\"b_attempt_error\":\"{s}\",\"checkpoint\":{{\"sequence\":0,\"terminal_mask\":{d},\"reclaimed_mask\":{d},\"remaining_live_mask\":{d},\"tree_payload_bytes\":{d},\"tree_active_nodes\":{d},\"bank_used_kv_bytes\":{d},\"bank_used_host_bytes\":{d},\"proposal_sha256\":\"{s}\",\"commit_sha256\":\"{s}\"}},",
        .{
            policy_key,
            arm.policy.label(),
            if (arm.policy == .retain) 0 else width,
            if (arm.policy == .retain) 0 else width,
            arm.a.duration_ns,
            arm.b_attempt.duration_ns,
            arm.b_reference.duration_ns,
            failure_name,
            arm.checkpoint.terminal_mask,
            arm.checkpoint.reclaimed_mask,
            arm.checkpoint.remaining_live_mask,
            arm.checkpoint.tree.current.kv_bytes,
            arm.checkpoint.tree.active_nodes,
            arm.checkpoint.bank.used.kv_bytes,
            try arm.checkpoint.bank.used.hostBytes(),
            &checkpoint_proposal,
            &checkpoint_commit,
        },
    );
    if (arm.failure_evidence) |failure| {
        try writer.print(
            "\"b_rejection\":{{\"kind\":\"capacity-exceeded\",\"failed_lane\":{d},\"transaction_sequence\":{d},\"tree_payload_bytes\":{d},\"tree_active_nodes\":{d},\"bank_used_kv_bytes\":{d},\"bank_used_host_bytes\":{d},\"bank_active_nodes\":{d},\"bank_live_allocations\":{d},\"rejected_lease_capacity\":{d},\"rejected_lease_nodes\":{d},\"committed_len\":[{d},{d},{d},{d}],\"allocated_pages\":[{d},{d},{d},{d}],\"committed_pages\":[{d},{d},{d},{d}],\"reusable_pages\":[{d},{d},{d},{d}]}} ,",
            .{
                failure.failed_lane,
                failure.transaction_sequence,
                failure.tree.current.kv_bytes,
                failure.tree.active_nodes,
                failure.bank.used.kv_bytes,
                try failure.bank.used.hostBytes(),
                failure.bank.active_lease_nodes,
                failure.bank.live_allocations,
                failure.bank.rejected_lease_capacity,
                failure.bank.rejected_lease_nodes,
                failure.lanes[0].root.committed_len,
                failure.lanes[1].root.committed_len,
                failure.lanes[2].root.committed_len,
                failure.lanes[3].root.committed_len,
                failure.lanes[0].allocation.allocated_pages,
                failure.lanes[1].allocation.allocated_pages,
                failure.lanes[2].allocation.allocated_pages,
                failure.lanes[3].allocation.allocated_pages,
                failure.lanes[0].allocation.committed_pages,
                failure.lanes[1].allocation.committed_pages,
                failure.lanes[2].allocation.committed_pages,
                failure.lanes[3].allocation.committed_pages,
                failure.lanes[0].allocation.reusable_pages,
                failure.lanes[1].allocation.reusable_pages,
                failure.lanes[2].allocation.reusable_pages,
                failure.lanes[3].allocation.reusable_pages,
            },
        );
    } else {
        try writer.writeAll("\"b_rejection\":null,");
    }
    try writer.print(
        "\"b_candidate_reference_state_equal\":{s},\"a_journal_head_sha256\":\"{s}\",\"b_reference_commit_sha256\":\"{s}\",\"final_bank_used_zero\":true,\"final_active_receipts\":{d},\"final_active_trees\":{d},\"final_active_nodes\":{d},\"b_reference_lane_states\":",
        .{
            if (arm.policy == .retain) "null" else "true",
            &a_head,
            &b_reference_commit,
            arm.final_snapshot.committed_receipts,
            arm.final_snapshot.active_lease_trees,
            arm.final_snapshot.active_lease_nodes,
        },
    );
    try writeAdmissionBStates(writer, &arm.b_reference);
    try writer.writeAll("}");
}

fn runAdmissionMainArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    const model_path = args[1];
    const ids_path = args[2];
    const mode = try AdmissionMode.parse(args[3]);
    const head_mode = try parseHead(args[4]);
    const pair_down_mode = try parsePairDown(args[5]);
    if (head_mode != .materialized) return error.InvalidUsage;

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
    var a_prompts = try buildPrompts(allocator, ids);
    defer freePrompts(allocator, &a_prompts);
    var a_forced: [width][max_new_tokens[width - 1]]u32 = undefined;
    const a_requests = buildRequests(&a_prompts, &a_forced);
    var b_prompts = try buildAdmissionBPrompts(allocator, ids);
    defer freePrompts(allocator, &b_prompts);
    var b_forced: [width][2]u32 = undefined;
    const b_requests = buildAdmissionBRequests(&b_prompts, &b_forced);

    const a_envelope = try deriveEnvelope(
        model,
        a_requests,
        .retain,
        head_mode,
        pair_down_mode,
    );
    const page_payload_bytes = try validateEnvelope(model, a_envelope);
    const a_immediate_envelope = try deriveEnvelope(
        model,
        a_requests,
        .immediate,
        head_mode,
        pair_down_mode,
    );
    if (!std.meta.eql(a_envelope, a_immediate_envelope))
        return error.InvalidEvidence;
    const b_envelope = try deriveAdmissionBEnvelope(
        model,
        b_requests,
        head_mode,
        pair_down_mode,
    );
    try validateAdmissionBEnvelope(b_envelope, page_payload_bytes);

    // The generation allocator must be safe for A's caller thread and B's
    // caller thread concurrently. Model/artifact ownership stays on the GPA.
    const generation_allocator = std.heap.c_allocator;
    var retain: ?AdmissionArm = null;
    defer if (retain) |*arm| arm.deinit();
    var reclaim: ?AdmissionArm = null;
    defer if (reclaim) |*arm| arm.deinit();
    switch (mode) {
        .retain_reclaim => {
            retain = try runAdmissionArm(
                generation_allocator,
                model,
                a_requests,
                b_requests,
                .retain,
                a_envelope,
                b_envelope,
                page_payload_bytes,
                head_mode,
                pair_down_mode,
                0x5032_4c41_0000_1000,
            );
            reclaim = try runAdmissionArm(
                generation_allocator,
                model,
                a_requests,
                b_requests,
                .immediate,
                a_envelope,
                b_envelope,
                page_payload_bytes,
                head_mode,
                pair_down_mode,
                0x5032_4c41_0000_2000,
            );
        },
        .reclaim_retain => {
            reclaim = try runAdmissionArm(
                generation_allocator,
                model,
                a_requests,
                b_requests,
                .immediate,
                a_envelope,
                b_envelope,
                page_payload_bytes,
                head_mode,
                pair_down_mode,
                0x5032_4c41_0000_3000,
            );
            retain = try runAdmissionArm(
                generation_allocator,
                model,
                a_requests,
                b_requests,
                .retain,
                a_envelope,
                b_envelope,
                page_payload_bytes,
                head_mode,
                pair_down_mode,
                0x5032_4c41_0000_4000,
            );
        },
        .retain_only => retain = try runAdmissionArm(
            generation_allocator,
            model,
            a_requests,
            b_requests,
            .retain,
            a_envelope,
            b_envelope,
            page_payload_bytes,
            head_mode,
            pair_down_mode,
            0x5032_4c41_0000_5000,
        ),
        .reclaim_only => reclaim = try runAdmissionArm(
            generation_allocator,
            model,
            a_requests,
            b_requests,
            .immediate,
            a_envelope,
            b_envelope,
            page_payload_bytes,
            head_mode,
            pair_down_mode,
            0x5032_4c41_0000_6000,
        ),
    }
    if (mode.isDual()) {
        try validateEqual(&retain.?.a, &reclaim.?.a);
        try validateAdmissionBEqual(
            &reclaim.?.b_attempt,
            &retain.?.b_reference,
        );
        try validateAdmissionBEqual(
            &reclaim.?.b_reference,
            &retain.?.b_reference,
        );
    }

    try requireUnchanged(executable_path, executable.stat);
    try requireUnchanged(model_path, model_file.stat);
    try requireUnchanged(ids_path, ids_file.stat);
    const executable_hex = std.fmt.bytesToHex(executable.sha256, .lower);
    const model_hex = std.fmt.bytesToHex(model_file.sha256, .lower);
    const ids_hex = std.fmt.bytesToHex(ids_file.sha256, .lower);
    const source_hex = std.fmt.bytesToHex(model.source_fingerprint, .lower);

    const stdout = std.fs.File.stdout();
    var output_buffer: [128 * 1024]u8 = undefined;
    var buffered = std.fs.File.Writer.init(stdout, &output_buffer);
    const writer = &buffered.interface;
    try writer.print(
        "{{\"schema\":\"{s}\",\"publishable\":false,\"reason\":\"actual-model-two-cohort-causal-evidence-without-independent-verifier-or-fault-schedule-campaign\",\"speed_claim\":false,\"timing_is_diagnostic_only\":true,\"actual_model\":true,\"shared_resource_bank\":true,\"cooperative_quiescent_yield\":true,\"mode\":\"{s}\",\"dual_arm_state_equal\":{s},\"causal_oracle\":{s},\"a_prompt_tokens_per_lane\":{d},\"a_published_tokens_per_lane\":[1,17,33,65],\"b_prompt_tokens_per_lane\":{d},\"b_published_tokens_per_lane\":[1,1,1,1],\"capacity_kv_positions\":{d},\"head_mode\":\"{s}\",\"attention_mode\":\"serial\",\"pair_down_mode\":\"{s}\",\"runner_sha256\":\"{s}\",\"runner_size_bytes\":{d},\"model_sha256\":\"{s}\",\"model_size_bytes\":{d},\"ids_sha256\":\"{s}\",\"ids_size_bytes\":{d},\"model_source_sha256\":\"{s}\",",
        .{
            admission_schema,
            mode.label(),
            if (mode.isDual()) "true" else "null",
            if (mode.isDual()) "true" else "null",
            prompt_len,
            admission_b_prompt_len,
            capacity_positions,
            headLabel(head_mode),
            pairDownLabel(pair_down_mode),
            &executable_hex,
            executable.stat.size,
            &model_hex,
            model_file.stat.size,
            &ids_hex,
            ids_file.stat.size,
            &source_hex,
        },
    );
    const limits = try admissionSharedLimits(page_payload_bytes);
    try writer.print(
        "\"geometry\":{{\"page_positions\":{d},\"page_payload_bytes\":{d},\"page_map_bytes_per_cohort\":{d},\"binding_storage_bytes_per_cohort\":{d},\"shared_slot_count\":2,\"shared_root_count\":2,\"shared_node_count\":{d},\"slot_pool_bytes\":{d},\"root_pool_bytes\":{d},\"node_pool_bytes\":{d}}},\"shared_limits\":{{\"host_bytes\":{d},\"capsule_bytes\":{d},\"kv_bytes\":{d},\"activation_bytes\":{d},\"logits_bytes\":{d},\"output_journal_bytes\":{d},\"staging_bytes\":{d},\"queue_slots\":{d}}},\"abis\":{{\"decode_lane4\":\"{x:0>16}\",\"paged_lease_decode\":\"{x:0>16}\",\"resource_bank\":\"{x:0>16}\",\"lease_tree\":\"{x:0>16}\",\"paged_lease_token_txn\":\"{x:0>16}\",\"wave_observer\":\"{x:0>16}\",\"admission_observer\":\"{x:0>16}\"}},\"arms\":{{",
        .{
            engine.paged_kv_cache.page_positions,
            page_payload_bytes,
            a_envelope.page_map_bytes,
            a_envelope.binding_storage_bytes,
            admission_lease_nodes,
            2 * @sizeOf(core.resource_bank.Slot),
            2 * @sizeOf(core.resource_bank.LeaseTreeRootSlot),
            admission_lease_nodes * @sizeOf(core.resource_bank.LeaseNodeSlot),
            limits.host_bytes,
            limits.capsule_bytes,
            limits.kv_bytes,
            limits.activation_bytes,
            limits.logits_bytes,
            limits.output_journal_bytes,
            limits.staging_bytes,
            limits.queue_slots,
            engine.decode_lane4.abi,
            engine.decode_lane4.paged_lease_decode_abi,
            core.resource_bank.abi,
            core.resource_bank.lease_tree_abi,
            engine.paged_lease_token_txn.abi,
            engine.decode_lane4.paged_lease_wave_observer_abi,
            engine.decode_lane4.paged_lease_admission_observer_abi,
        },
    );
    var wrote_arm = false;
    if (retain) |*arm| {
        try writeAdmissionArm(writer, arm);
        wrote_arm = true;
    }
    if (reclaim) |*arm| {
        if (wrote_arm) try writer.writeAll(",");
        try writeAdmissionArm(writer, arm);
    }
    try writer.writeAll("}}}\n");
    try buffered.interface.flush();
}

fn runMain(allocator: std.mem.Allocator) !void {
    if (builtin.cpu.arch != .aarch64) return error.AArch64Required;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 6) return error.InvalidUsage;
    if (runner_options.admission_cli)
        return runAdmissionMainArgs(allocator, args);

    const model_path = args[1];
    const ids_path = args[2];
    const mode = try Mode.parse(args[3]);
    const head_mode = try parseHead(args[4]);
    const pair_down_mode = try parsePairDown(args[5]);
    // Forced-token lifecycle evidence requires materialized logits; the
    // streamed head contract intentionally rejects forced decisions.
    if (head_mode != .materialized) return error.InvalidUsage;

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
    var forced: [width][max_new_tokens[width - 1]]u32 = undefined;
    const requests = buildRequests(&prompts, &forced);

    const envelope = try deriveEnvelope(
        model,
        requests,
        .retain,
        head_mode,
        pair_down_mode,
    );
    const page_payload_bytes = try validateEnvelope(model, envelope);
    const immediate_envelope = try deriveEnvelope(
        model,
        requests,
        .immediate,
        head_mode,
        pair_down_mode,
    );
    if (!std.meta.eql(envelope, immediate_envelope))
        return error.InvalidEvidence;

    var retain: ?Run = null;
    defer if (retain) |*run| run.deinit();
    var immediate: ?Run = null;
    defer if (immediate) |*run| run.deinit();
    switch (mode) {
        .retain_immediate => {
            retain = try runPolicy(
                allocator,
                model,
                requests,
                .retain,
                envelope,
                page_payload_bytes,
                head_mode,
                pair_down_mode,
                0x5032_4c45_0000_0101,
            );
            immediate = try runPolicy(
                allocator,
                model,
                requests,
                .immediate,
                envelope,
                page_payload_bytes,
                head_mode,
                pair_down_mode,
                0x5032_4c45_0000_0102,
            );
        },
        .immediate_retain => {
            immediate = try runPolicy(
                allocator,
                model,
                requests,
                .immediate,
                envelope,
                page_payload_bytes,
                head_mode,
                pair_down_mode,
                0x5032_4c45_0000_0201,
            );
            retain = try runPolicy(
                allocator,
                model,
                requests,
                .retain,
                envelope,
                page_payload_bytes,
                head_mode,
                pair_down_mode,
                0x5032_4c45_0000_0202,
            );
        },
        .retain_only => retain = try runPolicy(
            allocator,
            model,
            requests,
            .retain,
            envelope,
            page_payload_bytes,
            head_mode,
            pair_down_mode,
            0x5032_4c45_0000_0301,
        ),
        .immediate_only => immediate = try runPolicy(
            allocator,
            model,
            requests,
            .immediate,
            envelope,
            page_payload_bytes,
            head_mode,
            pair_down_mode,
            0x5032_4c45_0000_0401,
        ),
    }
    if (retain) |*run|
        try validateCompletedRun(run, .retain, page_payload_bytes);
    if (immediate) |*run|
        try validateCompletedRun(run, .immediate, page_payload_bytes);
    if (mode.isDual()) try validateEqual(&retain.?, &immediate.?);

    try requireUnchanged(executable_path, executable.stat);
    try requireUnchanged(model_path, model_file.stat);
    try requireUnchanged(ids_path, ids_file.stat);
    const executable_hex = std.fmt.bytesToHex(executable.sha256, .lower);
    const model_hex = std.fmt.bytesToHex(model_file.sha256, .lower);
    const ids_hex = std.fmt.bytesToHex(ids_file.sha256, .lower);
    const source_hex = std.fmt.bytesToHex(model.source_fingerprint, .lower);

    const stdout = std.fs.File.stdout();
    var output_buffer: [128 * 1024]u8 = undefined;
    var buffered = std.fs.File.Writer.init(stdout, &output_buffer);
    const writer = &buffered.interface;
    try writer.print(
        "{{\"schema\":\"{s}\",\"publishable\":false,\"reason\":\"single-cohort-token-txn-v3-abi4-lifecycle-evidence-not-stepped-co-resident-or-physical-confidence-campaign\",\"timing_scope\":\"generate-call-including-request-setup-and-teardown-excluding-model-load-envelope-and-json\",\"ordered_single_observation_per_role\":true,\"mode\":\"{s}\",\"cross_policy_state_equal\":{s},\"prompt_tokens_per_lane\":{d},\"published_tokens_per_lane\":[1,17,33,65],\"terminal_kv_positions\":[128,144,160,192],\"capacity_kv_positions\":{d},\"head_mode\":\"{s}\",\"attention_mode\":\"serial\",\"pair_down_mode\":\"{s}\",\"runner_sha256\":\"{s}\",\"runner_size_bytes\":{d},\"model_sha256\":\"{s}\",\"model_size_bytes\":{d},\"ids_sha256\":\"{s}\",\"ids_size_bytes\":{d},\"model_source_sha256\":\"{s}\",\"abis\":{{\"decode_lane4\":\"{x:0>16}\",\"paged_lease_decode\":\"{x:0>16}\",\"resource_bank\":\"{x:0>16}\",\"lease_tree\":\"{x:0>16}\",\"paged_kv\":\"{x:0>16}\",\"leased_paged_kv\":\"{x:0>16}\",\"paged_lease_token_txn_v3\":\"{x:0>16}\",\"paged_lease_sink\":\"{x:0>16}\",\"paged_lease_commit_receipt\":\"{x:0>16}\",\"resource_commitment\":\"{x:0>16}\",\"terminal_seal_v3\":\"{x:0>16}\"}},",
        .{
            schema,
            mode.label(),
            if (mode.isDual()) "true" else "null",
            prompt_len,
            capacity_positions,
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
            engine.decode_lane4.paged_lease_decode_abi,
            core.resource_bank.abi,
            core.resource_bank.lease_tree_abi,
            engine.paged_kv_cache.abi,
            engine.leased_paged_kv_cache.abi,
            engine.paged_lease_token_txn.abi,
            engine.paged_lease_token_txn.sink_abi,
            engine.paged_lease_token_txn.commit_receipt_abi,
            engine.paged_lease_token_txn.resource_commitment_abi,
            engine.leased_paged_kv_cache.terminal_seal_v3_abi,
        },
    );
    try writer.print(
        "\"geometry\":{{\"page_positions\":{d},\"page_payload_bytes\":{d},\"page_map_bytes\":{d},\"binding_storage_bytes\":{d},\"bounded_payload_bytes\":{d},\"actual_terminal_payload_bytes\":{d},\"required_roots\":{d},\"required_nodes\":{d},\"slot_bytes\":{d},\"root_slot_bytes\":{d},\"node_slot_bytes\":{d},\"binding_record_bytes\":{d}}},",
        .{
            engine.paged_kv_cache.page_positions,
            page_payload_bytes,
            envelope.page_map_bytes,
            envelope.binding_storage_bytes,
            envelope.bounded_peak_payload_bytes,
            page_payload_bytes * 39,
            envelope.required_lease_roots,
            envelope.required_lease_nodes,
            @sizeOf(core.resource_bank.Slot),
            @sizeOf(core.resource_bank.LeaseTreeRootSlot),
            @sizeOf(core.resource_bank.LeaseNodeSlot),
            @sizeOf(engine.leased_paged_kv_cache.PageLeaseBindingV1),
        },
    );
    var wrote_run = false;
    if (retain) |*run| {
        try writeRun(writer, run, .retain);
        wrote_run = true;
    }
    if (immediate) |*run| {
        if (wrote_run) try writer.writeAll(",");
        try writeRun(writer, run, .immediate);
    }
    if (mode.isDual()) try writer.print(
        ",\"descriptive_ordered_immediate_over_retain_generate_call_rate\":{d:.9}",
        .{try rate(immediate.?.duration_ns) / try rate(retain.?.duration_ns)},
    );
    try writer.writeAll(",");
    try writeLaneStates(writer, if (immediate) |*run| run else &retain.?);
    try writer.writeAll("}\n");
    try buffered.interface.flush();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const run_result = runMain(gpa.allocator());
    const deinit_status = gpa.deinit();
    try run_result;
    if (deinit_status == .leak) return error.MemoryLeak;
}

const SyntheticSequenceZero = struct {
    envelope: engine.decode_lane4.ResourceAdmissionEnvelope,
    proposal: engine.paged_lease_token_txn.ProposalV3,
};

fn filledDigest(byte: u8) [32]u8 {
    var digest: [32]u8 = undefined;
    @memset(&digest, byte);
    return digest;
}

fn syntheticSequenceZero() SyntheticSequenceZero {
    const page_payload_bytes: u64 = 393_216;
    const parent_claim: core.resource_bank.Claim = .{
        .capsule_bytes = 55_296,
        .kv_bytes = 2_048,
        .activation_bytes = 170_112,
        .logits_bytes = 2_430_992,
        .output_journal_bytes = 480,
        .staging_bytes = 49_408,
        .queue_slots = width,
    };
    const ceiling: core.resource_bank.Claim = .{
        .kv_bytes = 43 * page_payload_bytes,
    };
    const envelope: engine.decode_lane4.ResourceAdmissionEnvelope = .{
        .parent_claim = parent_claim,
        .bounded_peak_claim = parent_claim,
        .child_ceiling = .{},
        .logical_kv_capacity_bytes = 50_333_696,
        .page_map_bytes = 2_048,
        .bounded_peak_payload_bytes = 43 * page_payload_bytes,
        .binding_storage_bytes = 55_296,
        .lease_tree_ceiling = ceiling,
        .lane_bounded_payload_bytes = .{
            9 * page_payload_bytes,
            10 * page_payload_bytes,
            11 * page_payload_bytes,
            13 * page_payload_bytes,
        },
        .required_lease_roots = 1,
        .required_lease_nodes = 47,
        .paged_admission_mode = .lease_tree_required,
    };
    var proposal: engine.paged_lease_token_txn.ProposalV3 = .{
        .execution_abi = engine.decode_lane4.paged_lease_decode_abi,
        .request_epoch = 0x5032_4c45_5359_4e01,
        .transaction_sequence = 0,
        .resource_permit_generation = 1,
        .live_mask = 0b1111,
        .live_lane_count = width,
        .parent_receipt = .{
            .bank_epoch = 7,
            .slot_index = 0,
            .generation = 1,
            .owner_key = 9,
            .claim = parent_claim,
            .integrity = 11,
        },
        .tree = .{
            .tree_key = 13,
            .identity_generation = 15,
            .generation = 17,
            .structural_revision = 69,
            .ceiling = ceiling,
            .current = .{ .kv_bytes = 32 * page_payload_bytes },
            .active_nodes = 36,
            .state_digest = 21,
            .token_integrity = 23,
        },
    };
    for (0..width) |lane| {
        const ownership = filledDigest(@intCast(0x20 + lane));
        const canonical = filledDigest(@intCast(0x30 + lane));
        const allocation = filledDigest(@intCast(0x50 + lane));
        const cache_instance: u64 = 100 + lane;
        const root: engine.paged_kv_cache.PageMapRootV1 = .{
            .cache_instance = cache_instance,
            .generation = expectedRootGeneration(0, lane),
            .committed_len = prompt_len,
            .committed_pages = pagesForPositions(prompt_len),
            .ownership_sha256 = ownership,
        };
        const state_chain = expectedInitialStateChain(canonical, root);
        proposal.resources[lane] = .{
            .lane_index = @intCast(lane),
            .lifecycle = .live,
            .coordinator_instance = 300 + lane,
            .cache_instance = cache_instance,
            .scope_index = @intCast(lane),
            .scope_generation = 400 + lane,
            .root = root,
            .kv_state_chain_after = state_chain,
            .has_canonical_after = true,
            .canonical_after_sha256 = canonical,
            .has_terminal_generation = lane == 0,
            .terminal_generation = if (lane == 0)
                expectedRootGeneration(0, lane)
            else
                0,
            .has_binding_summary = true,
            .binding_summary = .{
                .count = @intCast(pagesForPositions(prompt_len)),
                .payload_bytes = @as(
                    u64,
                    @intCast(pagesForPositions(prompt_len)),
                ) * page_payload_bytes,
                .digest = filledDigest(@intCast(0x40 + lane)),
            },
            .allocation_set = .{
                .count = @intCast(pagesForPositions(prompt_len)),
                .payload_bytes = @as(
                    u64,
                    @intCast(pagesForPositions(prompt_len)),
                ) * page_payload_bytes,
                .sha256 = allocation,
            },
        };
        proposal.lanes[lane] = .{
            .lane_index = @intCast(lane),
            .step_index = 0,
            .prompt_len = prompt_len,
            .kv_before = prompt_len,
            .kv_after = prompt_len,
            .has_kv_transition = false,
            .kv_transition = .{
                .cache_instance = cache_instance,
                .root_before_generation = root.generation,
                .root_after_generation = root.generation,
                .root_before_len = root.committed_len,
                .root_after_len = root.committed_len,
                .root_before_pages = root.committed_pages,
                .root_after_pages = root.committed_pages,
                .root_before_ownership_sha256 = ownership,
                .root_after_ownership_sha256 = ownership,
                .initial_logical_kv_sha256 = canonical,
                .state_chain_before = state_chain,
                .state_chain_after = state_chain,
            },
            .output_before = 0,
            .output_after = 1,
            .output_sha256 = expectedOutputSha256(lane, 1),
            .rng_before = expectedInitialRng(lane),
            .rng_after = expectedInitialRng(lane),
            .sampling_calls_before = 0,
            .sampling_calls_after = 0,
            .token_id = if (lane == 0) eos_token else non_eos_token,
            .terminal_reason = if (lane == 0) .eos else null,
        };
    }
    return .{ .envelope = envelope, .proposal = proposal };
}

fn syntheticNextProposal(
    previous: engine.paged_lease_token_txn.ProposalV3,
    sequence: usize,
) engine.paged_lease_token_txn.ProposalV3 {
    std.debug.assert(sequence == previous.transaction_sequence + 1);
    std.debug.assert(sequence == 1 or sequence == 2);
    const page_payload_bytes: u64 = 393_216;
    var proposal = previous;
    proposal.transaction_sequence = sequence;
    proposal.resource_permit_generation += 1;
    proposal.live_mask = expectedMask(sequence);
    proposal.live_lane_count = @popCount(proposal.live_mask);
    proposal.tree.current.kv_bytes = expectedTreePayloadBytes(
        .retain,
        sequence,
        page_payload_bytes,
    );
    proposal.tree.active_nodes = expectedActiveNodes(.retain, sequence);
    if (expectedTreeStructureChanged(.retain, sequence)) {
        const delta = expectedTreeTransitionDelta(.retain, sequence);
        proposal.tree.generation += delta.generation;
        proposal.tree.structural_revision += delta.structural_revision;
        proposal.tree.state_digest += 1;
        proposal.tree.token_integrity += 1;
    }

    for (0..width) |lane| {
        const active = sequence < published_tokens[lane];
        proposal.resources[lane].lifecycle = expectedLifecycle(
            .retain,
            sequence,
            lane,
        );
        proposal.resources[lane].has_terminal_generation = false;
        proposal.resources[lane].terminal_generation = 0;
        if (!active) {
            proposal.lanes[lane] = .{};
            continue;
        }

        const previous_resource = previous.resources[lane];
        const row_position = prompt_len + sequence - 1;
        const installs_new_page = row_position %
            engine.paged_kv_cache.page_positions == 0;
        var root_after = previous_resource.root;
        root_after.generation += 1;
        root_after.committed_len = prompt_len + sequence;
        root_after.committed_pages = pagesForPositions(prompt_len + sequence);
        if (installs_new_page)
            root_after.ownership_sha256 = filledDigest(
                @intCast(0x80 + lane + sequence),
            );
        var transition: engine.paged_lease_token_txn.RootTransitionV3 = .{
            .cache_instance = previous_resource.cache_instance,
            .row_txn_generation = 500 + sequence * width + lane,
            .root_before_generation = previous_resource.root.generation,
            .root_after_generation = root_after.generation,
            .root_before_len = previous_resource.root.committed_len,
            .root_after_len = root_after.committed_len,
            .root_before_pages = previous_resource.root.committed_pages,
            .root_after_pages = root_after.committed_pages,
            .root_before_ownership_sha256 = previous_resource.root.ownership_sha256,
            .root_after_ownership_sha256 = root_after.ownership_sha256,
            .logical_page = row_position /
                engine.paged_kv_cache.page_positions,
            .page_ownership_generation = 700 + sequence * width + lane,
            .installs_new_page = installs_new_page,
            .row_payload_sha256 = filledDigest(
                @intCast(0xa0 + lane + sequence),
            ),
            .state_chain_before = previous_resource.kv_state_chain_after,
        };
        transition.state_chain_after = expectedAppendedStateChain(
            previous_resource.kv_state_chain_after,
            previous_resource.root,
            root_after,
            transition,
        );
        proposal.resources[lane].root = root_after;
        proposal.resources[lane].kv_state_chain_after =
            transition.state_chain_after;
        proposal.resources[lane].has_canonical_after = false;
        proposal.resources[lane].canonical_after_sha256 = [_]u8{0} ** 32;
        proposal.resources[lane].allocation_set.count = @intCast(
            expectedResourcePages(.retain, sequence, lane),
        );
        proposal.resources[lane].allocation_set.payload_bytes =
            @as(u64, proposal.resources[lane].allocation_set.count) *
            page_payload_bytes;
        proposal.resources[lane].has_binding_summary = true;
        proposal.resources[lane].binding_summary.count =
            proposal.resources[lane].allocation_set.count;
        proposal.resources[lane].binding_summary.payload_bytes =
            proposal.resources[lane].allocation_set.payload_bytes;
        if (installs_new_page) {
            proposal.resources[lane].binding_summary.digest = filledDigest(
                @intCast(0xb0 + lane + sequence),
            );
            proposal.resources[lane].allocation_set.sha256 = filledDigest(
                @intCast(0xc0 + lane + sequence),
            );
        }
        proposal.lanes[lane] = .{
            .lane_index = @intCast(lane),
            .step_index = sequence,
            .prompt_len = prompt_len,
            .kv_before = row_position,
            .kv_after = prompt_len + sequence,
            .has_kv_transition = true,
            .kv_transition = transition,
            .output_before = sequence,
            .output_after = sequence + 1,
            .output_sha256 = expectedOutputSha256(lane, sequence + 1),
            .rng_before = expectedInitialRng(lane),
            .rng_after = expectedInitialRng(lane),
            .sampling_calls_before = 0,
            .sampling_calls_after = 0,
            .token_id = non_eos_token,
        };
    }
    return proposal;
}

fn syntheticAck(
    proposal: engine.paged_lease_token_txn.ProposalV3,
) engine.paged_lease_token_txn.PrepareAckV3 {
    const proposal_sha256 = engine.paged_lease_token_txn.proposalSha256(proposal);
    return .{
        .proposal_sha256 = proposal_sha256,
        .sink_epoch = 29,
        .reservation_id = proposal.transaction_sequence + 1,
    };
}

fn syntheticReceipt(
    proposal: engine.paged_lease_token_txn.ProposalV3,
    ack: engine.paged_lease_token_txn.PrepareAckV3,
) engine.paged_lease_token_txn.CommitReceiptV3 {
    const proposal_sha256 = engine.paged_lease_token_txn.proposalSha256(proposal);
    const commit_sha256 = engine.paged_lease_token_txn.commitSha256(
        proposal_sha256,
        ack,
    );
    var receipt: engine.paged_lease_token_txn.CommitReceiptV3 = .{
        .proposal = proposal,
        .proposal_sha256 = proposal_sha256,
        .prepare_ack = ack,
        .commit_sha256 = commit_sha256,
    };
    for (proposal.lanes, 0..) |lane, lane_index| {
        if (lane.terminal_reason == null) continue;
        const resource = proposal.resources[lane_index];
        var seal: engine.leased_paged_kv_cache.TerminalSealV3 = .{
            .coordinator_instance = resource.coordinator_instance,
            .cache_instance = resource.cache_instance,
            .scope_index = resource.scope_index,
            .scope_generation = resource.scope_generation,
            .tree_identity_generation = proposal.tree.identity_generation,
            .tree_generation = proposal.tree.generation,
            .tree_structural_revision = proposal.tree.structural_revision,
            .tree_state_digest = proposal.tree.state_digest,
            .root = resource.root,
            .logical_kv_sha256 = resource.canonical_after_sha256,
            .bindings = .{
                .count = resource.binding_summary.count,
                .payload_bytes = resource.binding_summary.payload_bytes,
                .digest = resource.binding_summary.digest,
            },
            .allocation_set = resource.allocation_set,
            .transaction_sequence = proposal.transaction_sequence,
            .permit_generation = proposal.resource_permit_generation,
            .terminal_reason = .eos,
            .terminal_token = eos_token,
            .rng_after = lane.rng_after,
            .sampling_calls_after = lane.sampling_calls_after,
            .output_sha256 = lane.output_sha256,
            .proposal_sha256 = proposal_sha256,
            .commit_sha256 = commit_sha256,
            .generation = resource.terminal_generation,
            .digest = [_]u8{0} ** 32,
        };
        seal.digest = engine.leased_paged_kv_cache.terminalSealV3Digest(seal);
        receipt.terminal_seals[lane_index] = seal;
    }
    return receipt;
}

test "heterogeneous EOS trace fixes masks lifecycle and payload geometry" {
    try std.testing.expectEqual(@as(u8, 0b1111), expectedMask(0));
    try std.testing.expectEqual(@as(u8, 0b1110), expectedMask(1));
    try std.testing.expectEqual(@as(u8, 0b1110), expectedMask(16));
    try std.testing.expectEqual(@as(u8, 0b1100), expectedMask(17));
    try std.testing.expectEqual(@as(u8, 0b1100), expectedMask(32));
    try std.testing.expectEqual(@as(u8, 0b1000), expectedMask(33));
    try std.testing.expectEqual(@as(u8, 0b1000), expectedMask(64));
    try std.testing.expectEqual(@as(u8, 0), expectedMask(65));

    try std.testing.expectEqual(
        engine.leased_paged_kv_cache.LeaseLifecycle.live,
        expectedLifecycle(.retain, 0, 0),
    );
    try std.testing.expectEqual(
        engine.leased_paged_kv_cache.LeaseLifecycle.terminal_retained,
        expectedLifecycle(.retain, 1, 0),
    );
    try std.testing.expectEqual(
        engine.leased_paged_kv_cache.LeaseLifecycle.reclaimed,
        expectedLifecycle(.immediate, 1, 0),
    );

    const page_payload: u64 = 393_216;
    try std.testing.expectEqual(
        page_payload * 32,
        expectedTreePayloadBytes(.immediate, 0, page_payload),
    );
    try std.testing.expectEqual(
        page_payload * 39,
        expectedTreePayloadBytes(.retain, 64, page_payload),
    );
    try std.testing.expectEqual(
        page_payload * 12,
        expectedTreePayloadBytes(.immediate, 64, page_payload),
    );
    try std.testing.expectEqualDeep(
        TreeTransitionDelta{
            .allocation_batches = 3,
            .generation = 12,
            .structural_revision = 6,
        },
        expectedTreeTransitionDelta(.retain, 1),
    );
    try std.testing.expectEqualDeep(
        TreeTransitionDelta{
            .allocation_batches = 3,
            .reclaimed_scopes = 1,
            .generation = 17,
            .structural_revision = 9,
        },
        expectedTreeTransitionDelta(.immediate, 1),
    );
    try std.testing.expectEqual(@as(usize, 112), total_kv_transitions);
}

test "proposal validator cross-binds roots chains outputs rng and node count" {
    const synthetic = syntheticSequenceZero();
    var sink: Sink = .{
        .policy = .retain,
        .expected_envelope = synthetic.envelope,
        .expected_request_epoch = synthetic.proposal.request_epoch,
        .page_payload_bytes = 393_216,
    };
    try std.testing.expect(sink.validateProposal(synthetic.proposal));

    var forged = synthetic.proposal;
    forged.tree.active_nodes += 1;
    try std.testing.expect(!sink.validateProposal(forged));
    forged = synthetic.proposal;
    forged.resources[0].root.generation += 1;
    try std.testing.expect(!sink.validateProposal(forged));
    forged = synthetic.proposal;
    forged.resources[1].kv_state_chain_after = filledDigest(0x70);
    try std.testing.expect(!sink.validateProposal(forged));
    forged = synthetic.proposal;
    forged.resources[1].kv_state_chain_after = filledDigest(0x73);
    forged.lanes[1].kv_transition.state_chain_before = filledDigest(0x73);
    forged.lanes[1].kv_transition.state_chain_after = filledDigest(0x73);
    try std.testing.expect(!sink.validateProposal(forged));
    forged = synthetic.proposal;
    forged.lanes[2].output_sha256 = filledDigest(0x71);
    try std.testing.expect(!sink.validateProposal(forged));
    forged = synthetic.proposal;
    forged.lanes[3].rng_before[0] +%= 1;
    forged.lanes[3].rng_after = forged.lanes[3].rng_before;
    try std.testing.expect(!sink.validateProposal(forged));
    forged = synthetic.proposal;
    forged.resources[1].coordinator_instance =
        forged.resources[0].coordinator_instance;
    forged.resources[1].cache_instance = forged.resources[0].cache_instance;
    forged.resources[1].scope_index = forged.resources[0].scope_index;
    forged.resources[1].scope_generation = forged.resources[0].scope_generation;
    forged.resources[1].root.cache_instance = forged.resources[0].cache_instance;
    forged.lanes[1].kv_transition.cache_instance =
        forged.resources[0].cache_instance;
    const aliased_chain = expectedInitialStateChain(
        forged.resources[1].canonical_after_sha256,
        forged.resources[1].root,
    );
    forged.resources[1].kv_state_chain_after = aliased_chain;
    forged.lanes[1].kv_transition.state_chain_before = aliased_chain;
    forged.lanes[1].kv_transition.state_chain_after = aliased_chain;
    try std.testing.expect(!sink.validateProposal(forged));
    forged = synthetic.proposal;
    forged.resources[0].scope_index = width;
    try std.testing.expect(!sink.validateProposal(forged));
    forged = synthetic.proposal;
    forged.resources[1].binding_summary.digest =
        forged.resources[0].binding_summary.digest;
    try std.testing.expect(!sink.validateProposal(forged));
    forged = synthetic.proposal;
    forged.resources[2].allocation_set.sha256 =
        forged.resources[0].allocation_set.sha256;
    try std.testing.expect(!sink.validateProposal(forged));
    forged = synthetic.proposal;
    forged.resources[0].terminal_generation += 1;
    try std.testing.expect(!sink.validateProposal(forged));
    forged = synthetic.proposal;
    forged.abi_version -= 1;
    try std.testing.expect(!sink.validateProposal(forged));
    forged = synthetic.proposal;
    forged.leased_paged_kv_abi -= 1;
    try std.testing.expect(!sink.validateProposal(forged));
    forged = synthetic.proposal;
    forged.resources[0].abi_version -= 1;
    try std.testing.expect(!sink.validateProposal(forged));
}

test "proposal validator enforces changed and unchanged cross-wave authority" {
    const synthetic = syntheticSequenceZero();
    var sink: Sink = .{
        .policy = .retain,
        .expected_envelope = synthetic.envelope,
        .expected_request_epoch = synthetic.proposal.request_epoch,
        .page_payload_bytes = 393_216,
    };
    const interface = sink.interface();
    var first_ack: engine.paged_lease_token_txn.PrepareAckV3 = .{};
    try interface.prepare(interface.context, &synthetic.proposal, &first_ack);
    var first_receipt = syntheticReceipt(synthetic.proposal, first_ack);
    interface.commit(interface.context, &first_receipt);
    try std.testing.expect(sink.valid);
    try std.testing.expectEqual(@as(usize, 1), sink.commit_count);

    const second = syntheticNextProposal(synthetic.proposal, 1);
    try std.testing.expect(sink.validateProposal(second));
    var forged = second;
    forged.tree.generation = synthetic.proposal.tree.generation;
    forged.tree.structural_revision =
        synthetic.proposal.tree.structural_revision;
    try std.testing.expect(!sink.validateProposal(forged));
    forged = second;
    forged.resources[1].kv_state_chain_after = filledDigest(0x74);
    forged.lanes[1].kv_transition.state_chain_after = filledDigest(0x74);
    try std.testing.expect(!sink.validateProposal(forged));
    forged = second;
    forged.tree.generation += 1;
    try std.testing.expect(!sink.validateProposal(forged));
    forged = second;
    forged.tree.structural_revision += 1;
    try std.testing.expect(!sink.validateProposal(forged));

    var second_ack: engine.paged_lease_token_txn.PrepareAckV3 = .{};
    try interface.prepare(interface.context, &second, &second_ack);
    var second_receipt = syntheticReceipt(second, second_ack);
    interface.commit(interface.context, &second_receipt);
    try std.testing.expect(sink.valid);
    try std.testing.expectEqual(@as(usize, 2), sink.commit_count);

    const third = syntheticNextProposal(second, 2);
    try std.testing.expect(sink.validateProposal(third));
    forged = third;
    forged.tree.generation += 1;
    forged.tree.structural_revision += 1;
    forged.tree.state_digest += 1;
    forged.tree.token_integrity += 1;
    try std.testing.expect(!sink.validateProposal(forged));
    forged = third;
    forged.resources[1].binding_summary.digest[0] ^= 1;
    try std.testing.expect(!sink.validateProposal(forged));
    forged = third;
    forged.resources[2].allocation_set.sha256[0] ^= 1;
    try std.testing.expect(!sink.validateProposal(forged));
}

test "terminal seal binds proposal resource state and canonical digest" {
    const synthetic = syntheticSequenceZero();
    var sink: Sink = .{
        .policy = .retain,
        .expected_envelope = synthetic.envelope,
        .expected_request_epoch = synthetic.proposal.request_epoch,
        .page_payload_bytes = 393_216,
    };
    var receipt = syntheticReceipt(
        synthetic.proposal,
        syntheticAck(synthetic.proposal),
    );
    const seal = receipt.terminal_seals[0].?;
    try std.testing.expect(sink.validateTerminalSeal(&receipt, 0, seal));

    var forged = seal;
    forged.root.generation += 1;
    forged.digest = engine.leased_paged_kv_cache.terminalSealV3Digest(forged);
    try std.testing.expect(!sink.validateTerminalSeal(&receipt, 0, forged));
    forged = seal;
    forged.rng_after[0] +%= 1;
    forged.digest = engine.leased_paged_kv_cache.terminalSealV3Digest(forged);
    try std.testing.expect(!sink.validateTerminalSeal(&receipt, 0, forged));
    forged = seal;
    forged.allocation_set.payload_bytes += 393_216;
    forged.digest = engine.leased_paged_kv_cache.terminalSealV3Digest(forged);
    try std.testing.expect(!sink.validateTerminalSeal(&receipt, 0, forged));
    forged = seal;
    forged.bindings.digest[0] ^= 1;
    forged.digest = engine.leased_paged_kv_cache.terminalSealV3Digest(forged);
    try std.testing.expect(!sink.validateTerminalSeal(&receipt, 0, forged));
    forged = seal;
    forged.generation += 1;
    forged.digest = engine.leased_paged_kv_cache.terminalSealV3Digest(forged);
    try std.testing.expect(!sink.validateTerminalSeal(&receipt, 0, forged));
    forged = seal;
    forged.abi_version -= 1;
    forged.digest = engine.leased_paged_kv_cache.terminalSealV3Digest(forged);
    try std.testing.expect(!sink.validateTerminalSeal(&receipt, 0, forged));
    receipt.commit_sha256 = filledDigest(0x72);
    try std.testing.expect(!sink.validateTerminalSeal(&receipt, 0, seal));
}

test "commit rejects stale receipt ABI inside the trusted callback" {
    const synthetic = syntheticSequenceZero();
    var sink: Sink = .{
        .policy = .retain,
        .expected_envelope = synthetic.envelope,
        .expected_request_epoch = synthetic.proposal.request_epoch,
        .page_payload_bytes = 393_216,
    };
    const interface = sink.interface();
    var ack: engine.paged_lease_token_txn.PrepareAckV3 = .{};
    try interface.prepare(interface.context, &synthetic.proposal, &ack);
    var receipt = syntheticReceipt(synthetic.proposal, ack);
    receipt.abi_version -= 1;
    interface.commit(interface.context, &receipt);
    try std.testing.expect(!sink.valid);
}

test "final telemetry identity is the exact publication receipt" {
    const synthetic = syntheticSequenceZero();
    var sink: Sink = .{
        .policy = .retain,
        .expected_envelope = synthetic.envelope,
        .expected_request_epoch = synthetic.proposal.request_epoch,
        .page_payload_bytes = 393_216,
        .cohort_initialized = true,
        .parent_receipt = synthetic.proposal.parent_receipt,
    };
    const receipt = synthetic.proposal.parent_receipt;
    const telemetry: engine.decode_lane4.Telemetry = .{
        .token_txn_request_epoch = synthetic.proposal.request_epoch,
        .admitted_cohorts = 1,
        .cohort_width = width,
        .thread_participants = 4,
    };
    const resources: engine.generate.RequestResourceTelemetry = .{
        .owner_key = receipt.owner_key,
        .bank_epoch = receipt.bank_epoch,
        .receipt_slot_index = receipt.slot_index,
        .receipt_generation = receipt.generation,
        .receipt_integrity = receipt.integrity,
    };
    try std.testing.expect(finalPublicationIdentityMatches(
        &sink,
        telemetry,
        resources,
    ));

    var forged_telemetry = telemetry;
    forged_telemetry.token_txn_request_epoch += 1;
    try std.testing.expect(!finalPublicationIdentityMatches(
        &sink,
        forged_telemetry,
        resources,
    ));
    forged_telemetry = telemetry;
    forged_telemetry.admitted_cohorts = 2;
    try std.testing.expect(!finalPublicationIdentityMatches(
        &sink,
        forged_telemetry,
        resources,
    ));
    forged_telemetry = telemetry;
    forged_telemetry.thread_participants = 3;
    try std.testing.expect(!finalPublicationIdentityMatches(
        &sink,
        forged_telemetry,
        resources,
    ));

    var forged_resources = resources;
    forged_resources.owner_key += 1;
    try std.testing.expect(!finalPublicationIdentityMatches(
        &sink,
        telemetry,
        forged_resources,
    ));
    forged_resources = resources;
    forged_resources.receipt_integrity += 1;
    try std.testing.expect(!finalPublicationIdentityMatches(
        &sink,
        telemetry,
        forged_resources,
    ));
}
