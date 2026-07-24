//! Source, loose-file resume, and root-selected archive resume subprocess.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const engine = @import("engine");
const bundle = core.continuation_bundle;
const capsule = core.continuation_capsule;
const ownership = core.continuation_ownership_manifest;
const payload_store = core.continuation_object_payload_store;
const resource_bank = core.resource_bank;
const checkpoint_file = core.continuation_checkpoint_file;
const live = engine.continuation_live_restart;
const paged_kv = engine.paged_kv_cache;
const paged_restore = engine.continuation_paged_kv_restore;

const request_epoch: u64 = 71;
const source_bank_epoch: u64 = 81;
const target_bank_epoch: u64 = 82;
const checkpoint_generation: u64 = 4;
const checkpoint_sequence: u64 = 18;
const tenant_scope_sha256 = [_]u8{0x71} ** 32;
const challenge_sha256 = [_]u8{0x72} ** 32;
const parent_capsule_sha256 = [_]u8{0x73} ** 32;

const model_bytes = "model:restart-fixture";
const tokenizer_bytes = "tokenizer:restart-fixture";
const execution_plan_bytes = "plan:restart-fixture";
const lane_state_bytes = "lane:restart-fixture";

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len < 3 or arguments.len > 4)
        return error.InvalidArguments;
    var directory = try std.fs.openDirAbsolute(arguments[2], .{});
    defer directory.close();
    if (std.mem.eql(u8, arguments[1], "checkpoint")) {
        if (arguments.len != 3) return error.InvalidArguments;
        try writeCheckpointV1(allocator, directory);
    } else if (std.mem.eql(u8, arguments[1], "resume")) {
        if (arguments.len != 3) return error.InvalidArguments;
        try resumeCheckpointV1(allocator, directory);
    } else if (std.mem.eql(u8, arguments[1], "resume-set")) {
        if (arguments.len != 4) return error.InvalidArguments;
        try resumeCheckpointSetV1(
            allocator,
            directory,
            try std.fmt.parseInt(u64, arguments[3], 10),
        );
    } else return error.InvalidArguments;
}

fn writeCheckpointV1(
    allocator: std.mem.Allocator,
    directory: std.fs.Dir,
) !void {
    const ledger = try paged_kv.deriveCapacityLedger(1, 1, 32);
    const page_claim: resource_bank.Claim = .{
        .kv_bytes = @intCast(ledger.page_payload_bytes),
    };
    const tree_claim: resource_bank.Claim = .{
        .kv_bytes = @intCast(ledger.page_payload_bytes * 2),
    };
    const parent_claim: resource_bank.Claim = .{
        .kv_bytes = @intCast(ledger.page_map_bytes),
        .output_journal_bytes = live.runtime_state_bytes,
    };
    const total_host_bytes = try std.math.add(
        u64,
        try parent_claim.hostBytes(),
        try tree_claim.hostBytes(),
    );
    var slots = [_]resource_bank.Slot{.{}};
    var roots = [_]resource_bank.LeaseTreeRootSlot{.{}};
    var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 3;
    var bank = try resource_bank.Bank.initWithLeaseTree(
        &slots,
        &roots,
        &nodes,
        .{
            .host_bytes = total_host_bytes,
            .kv_bytes = parent_claim.kv_bytes + tree_claim.kv_bytes,
            .output_journal_bytes = parent_claim.output_journal_bytes,
        },
        source_bank_epoch,
    );
    const parent_receipt = try bank.commit(
        try bank.reserve(0x5101, parent_claim),
    );
    var tree = try bank.openLeaseTree(
        parent_receipt,
        0x5102,
        0x5103,
        tree_claim,
    );
    const opened = try bank.openLeaseScope(
        tree,
        0x5104,
        0x5105,
        tree_claim,
    );
    tree = opened.tree;
    var session_identity: u8 = 0;
    const session_id = @intFromPtr(&session_identity);
    try bank.bindRestoredPublicationSessionWithLeaseTree(
        tree,
        80,
        request_epoch,
        session_id,
        17,
    );
    const specs = [_]resource_bank.LeaseAllocationSpecV1{
        .{
            .scope = opened.scope,
            .node_key = 1,
            .binding_key = 0x5111,
            .claim = page_claim,
        },
        .{
            .scope = opened.scope,
            .node_key = 2,
            .binding_key = 0x5112,
            .claim = page_claim,
        },
    };
    var source_leaves: [2]resource_bank.LeaseNodeV1 = undefined;
    const reserved = try bank.reserveAllocationsForSession(
        tree,
        request_epoch,
        session_id,
        17,
        &specs,
        &source_leaves,
    );
    tree = reserved.tree;

    var cache = try paged_kv.PagedKVCache.init(allocator, 1, 1, 32);
    var cache_owned = true;
    errdefer if (cache_owned) cache.deinit();
    for (0..16) |position| try appendFixtureRowV1(&cache, position);
    const reusable = try cache.beginRow();
    try cache.abortRow(reusable);
    const resident = try cache.allocationCommitmentLedger();
    if (resident.allocated_pages != 2 or resident.committed_pages != 1 or
        resident.reusable_pages != 1)
        return error.InvalidSourceState;
    tree = try bank.commitAllocationsAfterAllocate(reserved.batch);

    var output_tokens = [_]u32{0} ** live.max_output_tokens;
    output_tokens[0] = 501;
    output_tokens[1] = 502;
    var runtime_state: live.RuntimeStateV1 = .{
        .request_epoch = request_epoch,
        .publication_next_sequence = 17,
        .checkpoint_generation = checkpoint_generation,
        .kv_tokens = 16,
        .output_token_count = 2,
        .sampling_calls = 2,
        .rng_state = .{ 11, 22, 33, 44 },
        .previous_commit_sha256 = [_]u8{0x61} ** 32,
        .logical_kv_sha256 = try cache.logicalKvSha256(),
        .challenge_sha256 = challenge_sha256,
        .output_tokens = output_tokens,
    };
    const source_keys = [_]f32{1601};
    const source_values = [_]f32{1602};
    const source_publication = try live.resumeOneTokenV1(
        .{
            .bank = &bank,
            .tree = tree,
            .request_epoch = request_epoch,
            .session_id = session_id,
        },
        &cache,
        &runtime_state,
        .{
            .token_id = 503,
            .rng_after = .{ 12, 23, 34, 45 },
            .sampling_calls_after = 3,
            .layer_keys = &source_keys,
            .layer_values = &source_values,
        },
    );
    if (source_publication.transaction_sequence != 17 or
        runtime_state.publication_next_sequence != checkpoint_sequence or
        runtime_state.kv_tokens != 17 or
        runtime_state.output_token_count != 3)
        return error.InvalidSourceState;

    var page_zero_storage: [512]u8 = undefined;
    const page_zero = try paged_restore.encodePageImageV1(
        &cache,
        0,
        challenge_sha256,
        &page_zero_storage,
    );
    var page_one_storage: [512]u8 = undefined;
    const page_one = try paged_restore.encodePageImageV1(
        &cache,
        1,
        challenge_sha256,
        &page_one_storage,
    );
    var payload_inputs = [_]payload_store.EntryInputV1{
        .{
            .reference = try bundle.blobRefV1(
                tenant_scope_sha256,
                page_zero,
            ),
            .payload = page_zero,
        },
        .{
            .reference = try bundle.blobRefV1(
                tenant_scope_sha256,
                page_one,
            ),
            .payload = page_one,
        },
    };
    payload_store.sortEntriesV1(&payload_inputs);
    var payload_storage: [2048]u8 = undefined;
    const payload_wire = try payload_store.encodeSnapshotV1(
        tenant_scope_sha256,
        &payload_inputs,
        &payload_storage,
    );
    var payload_entries: [payload_store.default_capacity]payload_store.EntryViewV1 = undefined;
    const payload_snapshot = try payload_store.decodeSnapshotV1(
        payload_wire,
        tenant_scope_sha256,
        &payload_entries,
    );
    const scopes = [_]ownership.ScopeInputV1{.{
        .scope_key = 0x5201,
        .tenant_key = 0x5202,
        .ceiling = tree_claim,
    }};
    const allocations = [_]ownership.AllocationInputV1{
        .{
            .scope_ordinal = 0,
            .node_key = 1,
            .binding_key = 0x5211,
            .kind = .kv_page,
            .claim = page_claim,
            .object_bytes = page_zero,
        },
        .{
            .scope_ordinal = 0,
            .node_key = 2,
            .binding_key = 0x5212,
            .kind = .kv_page,
            .claim = page_claim,
            .object_bytes = page_one,
        },
    };
    var manifest_storage: [ownership.encoded_bytes]u8 = undefined;
    const manifest_wire = try ownership.encodeV1(.{
        .source_bank_epoch = source_bank_epoch,
        .source_receipt_generation = parent_receipt.generation,
        .restore_bank_epoch = target_bank_epoch,
        .request_epoch = request_epoch,
        .publication_next_sequence = checkpoint_sequence,
        .checkpoint_generation = checkpoint_generation,
        .owner_key = 0x5301,
        .tree_key = 0x5302,
        .authority_key = 0x5303,
        .parent_claim = parent_claim,
        .tree_ceiling = tree_claim,
        .tenant_scope_sha256 = tenant_scope_sha256,
        .payload_snapshot_sha256 = payload_snapshot.snapshot_sha256,
        .challenge_sha256 = challenge_sha256,
        .scopes = &scopes,
        .allocations = &allocations,
    }, &manifest_storage);
    var runtime_storage: [live.runtime_state_bytes]u8 = undefined;
    const runtime_wire = try live.encodeRuntimeStateV1(
        runtime_state,
        &runtime_storage,
    );
    const objects = capsuleObjectsV1(
        manifest_wire,
        page_zero,
        runtime_wire,
    );
    const config = capsuleConfigV1();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    const capsule_wire = try capsule.encodeV1(
        config,
        objects,
        &capsule_storage,
    );
    _ = try capsule.decodeAndVerifyV1(capsule_wire, config, objects);

    try writeSyncedFileV1(directory, "capsule.bin", capsule_wire);
    try writeSyncedFileV1(directory, "manifest.bin", manifest_wire);
    try writeSyncedFileV1(directory, "payload.bin", payload_wire);
    try writeSyncedFileV1(directory, "page-0.bin", page_zero);
    try writeSyncedFileV1(directory, "page-1.bin", page_one);
    try writeSyncedFileV1(directory, "runtime.bin", runtime_wire);
    var pid_storage: [32]u8 = undefined;
    const pid_wire = try std.fmt.bufPrint(
        &pid_storage,
        "{d}",
        .{currentProcessId()},
    );
    try writeSyncedFileV1(directory, "source.pid", pid_wire);
    try std.posix.fsync(directory.fd);

    const retiring = try bank.beginRetireSubtreeForSession(
        tree,
        opened.scope,
        request_epoch,
        session_id,
        checkpoint_sequence,
    );
    const authorized = try bank.authorizeFree(retiring.ticket);
    cache.deinit();
    cache_owned = false;
    const empty_tree = try bank.commitFreeAfterAllocatorFree(
        authorized.permit,
    );
    try bank.closePublicationSession(
        parent_receipt,
        request_epoch,
        session_id,
        checkpoint_sequence,
    );
    try bank.closeLeaseTree(empty_tree);
    try bank.release(parent_receipt);
    if (!(try bank.snapshotV3()).used.isZero())
        return error.SourceOwnershipLeak;

    const commit_hex = std.fmt.bytesToHex(
        source_publication.commit_sha256,
        .lower,
    );
    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"phase\":\"checkpoint\",\"pid\":{d}," ++
            "\"next_sequence\":18,\"kv_tokens\":17,\"output_tokens\":3," ++
            "\"source_commit_sha256\":\"{s}\",\"verified\":true}}\n",
        .{ currentProcessId(), &commit_hex },
    );
    try stdout.flush();
}

fn resumeCheckpointV1(
    allocator: std.mem.Allocator,
    directory: std.fs.Dir,
) !void {
    const capsule_wire = try directory.readFileAlloc(
        allocator,
        "capsule.bin",
        capsule.encoded_bytes,
    );
    defer allocator.free(capsule_wire);
    const manifest_wire = try directory.readFileAlloc(
        allocator,
        "manifest.bin",
        ownership.encoded_bytes,
    );
    defer allocator.free(manifest_wire);
    const payload_wire = try directory.readFileAlloc(
        allocator,
        "payload.bin",
        2048,
    );
    defer allocator.free(payload_wire);
    const page_zero = try directory.readFileAlloc(
        allocator,
        "page-0.bin",
        512,
    );
    defer allocator.free(page_zero);
    const page_one = try directory.readFileAlloc(
        allocator,
        "page-1.bin",
        512,
    );
    defer allocator.free(page_one);
    const runtime_wire = try directory.readFileAlloc(
        allocator,
        "runtime.bin",
        live.runtime_state_bytes,
    );
    defer allocator.free(runtime_wire);
    const source_pid_wire = try directory.readFileAlloc(
        allocator,
        "source.pid",
        32,
    );
    defer allocator.free(source_pid_wire);
    try resumeCheckpointObjectsV1(
        allocator,
        capsule_wire,
        manifest_wire,
        payload_wire,
        page_zero,
        page_one,
        runtime_wire,
        source_pid_wire,
    );
}

fn resumeCheckpointSetV1(
    allocator: std.mem.Allocator,
    directory: std.fs.Dir,
    storage_epoch: u64,
) !void {
    var lock_storage: [1]u8 = undefined;
    var active_storage: [8192]u8 = undefined;
    var lease = try checkpoint_file.LeaseV1.open(
        directory,
        storage_epoch,
        challenge_sha256,
        active_storage.len,
        &lock_storage,
        &active_storage,
    );
    defer lease.close();
    const set = try lease.activeSet();
    const capsule_object = try set.object(.capsule, 0);
    const manifest_object = try set.object(.ownership_manifest, 0);
    const payload_object = try set.object(.payload_snapshot, 0);
    const page_zero = try set.object(.kv_page, 0);
    const page_one = try set.object(.kv_page, 1);
    const runtime_object = try set.object(.runtime_state, 0);
    const source_process = try set.object(.source_process, 0);
    if (capsule_object.abi_version != capsule.wire_abi or
        manifest_object.abi_version != ownership.abi_version or
        payload_object.abi_version != payload_store.schema_version or
        page_zero.abi_version != paged_restore.page_image_abi or
        page_one.abi_version != paged_restore.page_image_abi or
        runtime_object.abi_version != live.runtime_state_abi or
        source_process.abi_version != 1)
        return error.InvalidCheckpointSet;
    try resumeCheckpointObjectsV1(
        allocator,
        capsule_object.bytes,
        manifest_object.bytes,
        payload_object.bytes,
        page_zero.bytes,
        page_one.bytes,
        runtime_object.bytes,
        source_process.bytes,
    );
}

fn resumeCheckpointObjectsV1(
    allocator: std.mem.Allocator,
    capsule_wire: []const u8,
    manifest_wire: []const u8,
    payload_wire: []const u8,
    page_zero: []const u8,
    page_one: []const u8,
    runtime_wire: []const u8,
    source_pid_wire: []const u8,
) !void {
    const source_pid = try std.fmt.parseInt(
        u32,
        source_pid_wire,
        10,
    );
    const target_pid = currentProcessId();
    if (source_pid == target_pid) return error.ProcessDidNotRestart;

    const objects = capsuleObjectsV1(
        manifest_wire,
        page_zero,
        runtime_wire,
    );
    const config = capsuleConfigV1();
    var runtime_state = try live.restoreRuntimeStateV1(
        capsule_wire,
        config,
        objects,
        runtime_wire,
    );
    const manifest = try ownership.decodeV1(manifest_wire);
    const total_host_bytes = try std.math.add(
        u64,
        try manifest.parent_claim.hostBytes(),
        try manifest.tree_ceiling.hostBytes(),
    );
    const total_kv_bytes = try std.math.add(
        u64,
        manifest.parent_claim.kv_bytes,
        manifest.tree_ceiling.kv_bytes,
    );
    var slots = [_]resource_bank.Slot{.{}};
    var roots = [_]resource_bank.LeaseTreeRootSlot{.{}};
    var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 3;
    var bank = try resource_bank.Bank.initWithLeaseTree(
        &slots,
        &roots,
        &nodes,
        .{
            .host_bytes = total_host_bytes,
            .kv_bytes = total_kv_bytes,
            .output_journal_bytes = manifest.parent_claim.output_journal_bytes,
        },
        target_bank_epoch,
    );
    var session_identity: u8 = 0;
    const session_id = @intFromPtr(&session_identity);
    const prepared = try ownership.prepareReacquireV1(
        &bank,
        capsule_wire,
        manifest_wire,
        payload_wire,
        session_id,
    );
    const page_wires = [_][]const u8{ page_zero, page_one };
    var restored = try paged_restore.restoreAndCommitV1(
        allocator,
        &bank,
        prepared,
        manifest_wire,
        payload_wire,
        &page_wires,
    );
    if (restored.restore.source_root.cache_instance ==
        restored.restore.target_root.cache_instance or
        !std.mem.eql(
            u8,
            &try restored.cache.logicalKvSha256(),
            &runtime_state.logical_kv_sha256,
        )) return error.RestoredKvMismatch;
    const source_commit = runtime_state.previous_commit_sha256;
    const target_keys = [_]f32{1701};
    const target_values = [_]f32{1702};
    const resumed = try live.resumeOneTokenV1(
        .{
            .bank = &bank,
            .tree = restored.ownership_state.tree,
            .request_epoch = request_epoch,
            .session_id = session_id,
        },
        &restored.cache,
        &runtime_state,
        .{
            .token_id = 504,
            .rng_after = .{ 13, 24, 35, 46 },
            .sampling_calls_after = 4,
            .layer_keys = &target_keys,
            .layer_values = &target_values,
        },
    );
    if (resumed.transaction_sequence != checkpoint_sequence or
        !std.mem.eql(
            u8,
            &resumed.previous_commit_sha256,
            &source_commit,
        ) or
        runtime_state.publication_next_sequence != 19 or
        runtime_state.kv_tokens != 18 or
        runtime_state.output_token_count != 4 or
        !std.mem.eql(
            u32,
            runtime_state.output_tokens[0..4],
            &[_]u32{ 501, 502, 503, 504 },
        ) or
        !std.mem.eql(
            u8,
            &runtime_state.logical_kv_sha256,
            &try restored.cache.logicalKvSha256(),
        ))
        return error.InvalidResumedState;

    const source_commit_hex = std.fmt.bytesToHex(source_commit, .lower);
    const target_commit_hex = std.fmt.bytesToHex(
        resumed.commit_sha256,
        .lower,
    );
    const logical_kv_hex = std.fmt.bytesToHex(
        runtime_state.logical_kv_sha256,
        .lower,
    );
    const target_cache_instance = restored.cache.root().cache_instance;
    const source_cache_instance =
        restored.restore.source_root.cache_instance;

    const retiring = try bank.beginRetireSubtreeForSession(
        restored.ownership_state.tree,
        restored.ownership_state.scopes[0],
        request_epoch,
        session_id,
        19,
    );
    const authorized = try bank.authorizeFree(retiring.ticket);
    restored.cache.deinit();
    const empty_tree = try bank.commitFreeAfterAllocatorFree(
        authorized.permit,
    );
    try bank.closePublicationSession(
        restored.ownership_state.receipt,
        request_epoch,
        session_id,
        19,
    );
    try bank.closeLeaseTree(empty_tree);
    try bank.release(restored.ownership_state.receipt);
    if (!(try bank.snapshotV3()).used.isZero())
        return error.TargetOwnershipLeak;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.continuation-live-restart/demo-v1\"," ++
            "\"phase\":\"resume\",\"source_pid\":{d},\"target_pid\":{d}," ++
            "\"process_restart\":true,\"next_sequence\":19," ++
            "\"kv_tokens\":18,\"output_tokens\":[501,502,503,504]," ++
            "\"duplicate_output_tokens\":0," ++
            "\"source_cache_instance\":{d}," ++
            "\"target_cache_instance\":{d}," ++
            "\"source_commit_sha256\":\"{s}\"," ++
            "\"target_commit_sha256\":\"{s}\"," ++
            "\"logical_kv_sha256\":\"{s}\"," ++
            "\"final_bank_host_bytes\":0,\"verified\":true}}\n",
        .{
            source_pid,
            target_pid,
            source_cache_instance,
            target_cache_instance,
            &source_commit_hex,
            &target_commit_hex,
            &logical_kv_hex,
        },
    );
    try stdout.flush();
}

fn currentProcessId() u32 {
    if (comptime builtin.os.tag == .windows)
        return std.os.windows.GetCurrentProcessId();
    return @intCast(std.c.getpid());
}

fn capsuleConfigV1() capsule.ConfigV1 {
    return .{
        .execution_abi = 1,
        .request_epoch = request_epoch,
        .publication_sequence = checkpoint_sequence,
        .checkpoint_generation = checkpoint_generation,
        .kv_tokens = 17,
        .output_tokens = 3,
        .challenge_sha256 = challenge_sha256,
        .parent_capsule_sha256 = parent_capsule_sha256,
    };
}

fn capsuleObjectsV1(
    manifest_wire: []const u8,
    first_page_wire: []const u8,
    runtime_wire: []const u8,
) capsule.ObjectsV1 {
    return .{
        .model = .{ .abi_version = 1, .bytes = model_bytes },
        .tokenizer = .{ .abi_version = 2, .bytes = tokenizer_bytes },
        .execution_plan = .{
            .abi_version = 3,
            .bytes = execution_plan_bytes,
        },
        .resource_state = .{
            .abi_version = ownership.abi_version,
            .bytes = manifest_wire,
        },
        .lane_state = .{ .abi_version = 5, .bytes = lane_state_bytes },
        .kv_state = .{
            .abi_version = paged_restore.page_image_abi,
            .bytes = first_page_wire,
        },
        .sampler_state = .{
            .abi_version = live.runtime_state_abi,
            .bytes = runtime_wire,
        },
        .output_state = .{
            .abi_version = live.runtime_state_abi,
            .bytes = runtime_wire,
        },
        .publication_receipt = .{
            .abi_version = live.runtime_state_abi,
            .bytes = runtime_wire,
        },
    };
}

fn writeSyncedFileV1(
    directory: std.fs.Dir,
    name: []const u8,
    bytes: []const u8,
) !void {
    const file = try directory.createFile(name, .{
        .read = true,
        .truncate = true,
        .exclusive = true,
        .mode = 0o600,
    });
    defer file.close();
    try file.writeAll(bytes);
    try file.sync();
}

fn appendFixtureRowV1(
    cache: *paged_kv.PagedKVCache,
    position: usize,
) !void {
    const mark = try cache.beginRow();
    const base: f32 = @floatFromInt(position * 100);
    const key = [_]f32{base + 1};
    const value = [_]f32{base + 2};
    _ = try cache.appendRowTxn(mark, 0, &key, &value);
    try cache.commitRowTxn(mark);
}
