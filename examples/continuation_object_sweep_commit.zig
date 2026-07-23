//! Capability-scoped destructive sweep commit with exact reclamation evidence.

const std = @import("std");
const core = @import("core");
const capsule = core.continuation_capsule;
const bundle = core.continuation_bundle;
const object_store = core.continuation_object_store;
const sweep = core.continuation_object_sweep;

pub fn main() !void {
    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    const capsule_wire = try capsule.encodeV1(
        demoCapsuleConfig(),
        objects,
        &capsule_storage,
    );
    const bundle_config: bundle.ConfigV1 = .{
        .tenant_scope_sha256 = [_]u8{0x6d} ** 32,
        .capsule_sha256 = try capsule.envelopeRootV1(capsule_wire),
        .bundle_generation = 0,
        .challenge_sha256 = [_]u8{0xe3} ** 32,
    };
    var bundle_storage: [bundle.encoded_bytes]u8 = undefined;
    const bundle_wire = try bundle.encodeV1(
        bundle_config,
        capsule_wire,
        objects,
        &bundle_storage,
    );
    const bundle_root = try bundle.envelopeRootV1(bundle_wire);
    const store_grant = demoStoreGrant(bundle_root);
    const store_grant_root = try object_store.grantRootV1(store_grant);
    var allocator_storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_storage);
    var store = try object_store.Store.initV1(
        fba.allocator(),
        store_grant,
        store_grant.authority_epoch,
    );
    defer store.deinit();
    _ = try store.importBundleV1(
        bundle_wire,
        bundle_config,
        capsule_wire,
        objects,
    );

    const decoded = try bundle.decodeManifestV1(bundle_wire);
    const model_entry = decoded.entry(.model);
    const model: bundle.BlobRefV1 = .{
        .byte_length = model_entry.byte_length,
        .sha256 = model_entry.blob_sha256,
    };
    const lifecycle_grant = demoLifecycleGrant(
        store_grant,
        store_grant_root,
    );
    const lease = try store.acquireLeaseV1(
        model,
        lifecycle_grant,
        [_]u8{0x71} ** 32,
        100,
        120,
    );
    const retired_entry = decoded.entry(.publication_receipt);
    const retired_target: bundle.BlobRefV1 = .{
        .byte_length = retired_entry.byte_length,
        .sha256 = retired_entry.blob_sha256,
    };
    try store.retireV1(retired_target);
    const lane_entry = decoded.entry(.lane_state);
    try store.quarantineV1(.{
        .byte_length = lane_entry.byte_length,
        .sha256 = lane_entry.blob_sha256,
    }, [_]u8{0x9a} ** 32);

    var roots: [capsule.object_count - 1]bundle.BlobRefV1 = undefined;
    var root_count: usize = 0;
    for (capsule.object_kinds) |kind| {
        if (kind == .publication_receipt) continue;
        const entry = decoded.entry(kind);
        roots[root_count] = .{
            .byte_length = entry.byte_length,
            .sha256 = entry.blob_sha256,
        };
        root_count += 1;
    }
    if (root_count != roots.len) return error.RootFixtureMismatch;
    object_store.sortRootReferencesV1(&roots);
    var leases = [_]object_store.LeaseReceiptV1{lease};
    object_store.sortLeaseReceiptsV1(&leases);

    const snapshot_before = try store.auditSnapshotRootV2();
    const collection_grant: object_store.CollectionGrantV1 = .{
        .authority_epoch = store_grant.authority_epoch,
        .tenant_scope_sha256 = store_grant.tenant_scope_sha256,
        .bundle_sha256 = store_grant.bundle_sha256,
        .store_grant_sha256 = store_grant_root,
        .expected_snapshot_sha256 = snapshot_before,
        .max_root_references = 16,
        .max_lease_receipts = 4,
        .max_slot_scans = object_store.default_capacity,
        .max_collectible_entries = 2,
        .max_collectible_bytes = 128,
        .challenge_sha256 = [_]u8{0xe8} ** 32,
    };
    var decisions: [object_store.default_capacity]object_store.CollectionDecisionV1 =
        undefined;
    const plan = try store.planCollectionV1(
        collection_grant,
        &roots,
        &leases,
        &decisions,
    );
    const sweep_grant: sweep.GrantV1 = .{
        .authority_epoch = store_grant.authority_epoch,
        .tenant_scope_sha256 = store_grant.tenant_scope_sha256,
        .bundle_sha256 = store_grant.bundle_sha256,
        .store_grant_sha256 = store_grant_root,
        .expected_snapshot_sha256 = snapshot_before,
        .collection_plan_sha256 = plan.plan_sha256,
        .max_staged_entries = 2,
        .max_staged_bytes = 128,
        .challenge_sha256 = [_]u8{0xd4} ** 32,
    };
    const input_journal: sweep.JournalV1 = .{};
    const prepared = try sweep.prepareV1(
        &store,
        sweep_grant,
        collection_grant,
        &roots,
        &leases,
        input_journal,
    );
    const commit_grant: sweep.CommitGrantV1 = .{
        .authority_epoch = store_grant.authority_epoch,
        .tenant_scope_sha256 = store_grant.tenant_scope_sha256,
        .bundle_sha256 = store_grant.bundle_sha256,
        .store_grant_sha256 = store_grant_root,
        .sweep_grant_sha256 = try sweep.grantRootV1(sweep_grant),
        .prepare_sha256 = prepared.journal.prepare_sha256,
        .expected_snapshot_sha256 = prepared.journal.snapshot_sha256,
        .collection_plan_sha256 = prepared.journal.collection_plan_sha256,
        .max_freed_entries = 2,
        .max_freed_bytes = 128,
        .challenge_sha256 = [_]u8{0xd7} ** 32,
    };

    const allocator_before = fba.end_index;
    const committed = try sweep.commitV1(
        &store,
        sweep_grant,
        commit_grant,
        collection_grant,
        &roots,
        &leases,
        prepared.journal,
    );
    try sweep.verifyCommitReceiptV1(
        commit_grant,
        committed.receipt,
        committed.store_receipt,
    );
    try store.verifyAllV1();
    const allocator_after = fba.end_index;
    if (allocator_before != 255 or allocator_after != 216)
        return error.AllocatorReclamationMismatch;
    if (store.entry_count != 7 or store.retired_entries != 0 or
        store.payload_bytes != 216)
        return error.StoreAccountingMismatch;
    if (committed.receipt.freed_entries != 1 or
        committed.receipt.freed_payload_bytes != 39 or
        committed.receipt.freed_index_bytes !=
            object_store.logical_index_entry_bytes or
        committed.receipt.freed_repair_count != 0 or
        committed.receipt.allocator_deallocation_calls != 1)
        return error.CommitReceiptMismatch;
    if (input_journal.state != .empty or prepared.journal.state != .prepared)
        return error.InputJournalMutated;
    if (store.getV1(retired_target, &[_]u8{})) |_| {
        return error.RetiredTargetStillPresent;
    } else |err| switch (err) {
        object_store.Error.NotFound => {},
        else => return err,
    }

    const sweep_grant_hex = std.fmt.bytesToHex(
        try sweep.grantRootV1(sweep_grant),
        .lower,
    );
    const plan_hex = std.fmt.bytesToHex(plan.plan_sha256, .lower);
    const prepare_hex = std.fmt.bytesToHex(
        prepared.receipt.prepare_sha256,
        .lower,
    );
    const commit_grant_hex = std.fmt.bytesToHex(
        try sweep.commitGrantRootV1(commit_grant),
        .lower,
    );
    const targets_hex = std.fmt.bytesToHex(
        committed.receipt.targets_sha256,
        .lower,
    );
    const store_commit_hex = std.fmt.bytesToHex(
        committed.store_receipt.commit_sha256,
        .lower,
    );
    const commit_hex = std.fmt.bytesToHex(
        committed.receipt.commit_sha256,
        .lower,
    );
    const before_hex = std.fmt.bytesToHex(
        committed.receipt.snapshot_before_sha256,
        .lower,
    );
    const after_hex = std.fmt.bytesToHex(
        committed.receipt.snapshot_after_sha256,
        .lower,
    );
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.continuation-object-sweep-commit/demo-v1\"," ++
            "\"freed_entries\":{d},\"freed_payload_bytes\":{d}," ++
            "\"freed_index_bytes\":{d}," ++
            "\"freed_repair_count\":{d}," ++
            "\"allocator_deallocation_calls\":{d}," ++
            "\"allocator_consumed_before\":{d}," ++
            "\"allocator_consumed_after\":{d}," ++
            "\"allocator_consumed_reclaimed\":{d}," ++
            "\"entry_count_before\":8,\"entry_count_after\":{d}," ++
            "\"retired_entries_before\":1,\"retired_entries_after\":{d}," ++
            "\"store_payload_before\":255,\"store_payload_after\":{d}," ++
            "\"journal_bytes\":{d},\"native_store_bytes\":{d}," ++
            "\"sweep_heap_allocations\":0," ++
            "\"target_was_allocator_tail\":true," ++
            "\"all_fallible_checks_before_deallocation\":true," ++
            "\"collection_plan_regenerated\":true," ++
            "\"input_journal_unchanged\":true," ++
            "\"filesystem_authority\":false," ++
            "\"network_authority\":false,\"clock_authority\":false," ++
            "\"durable\":false,\"secure_erase\":false," ++
            "\"sweep_grant_sha256\":\"{s}\"," ++
            "\"collection_plan_sha256\":\"{s}\"," ++
            "\"prepare_sha256\":\"{s}\"," ++
            "\"commit_grant_sha256\":\"{s}\"," ++
            "\"targets_sha256\":\"{s}\"," ++
            "\"store_commit_sha256\":\"{s}\"," ++
            "\"commit_sha256\":\"{s}\"," ++
            "\"snapshot_before_sha256\":\"{s}\"," ++
            "\"snapshot_after_sha256\":\"{s}\",\"verified\":true}}\n",
        .{
            committed.receipt.freed_entries,
            committed.receipt.freed_payload_bytes,
            committed.receipt.freed_index_bytes,
            committed.receipt.freed_repair_count,
            committed.receipt.allocator_deallocation_calls,
            allocator_before,
            allocator_after,
            allocator_before - allocator_after,
            store.entry_count,
            store.retired_entries,
            store.payload_bytes,
            @sizeOf(sweep.JournalV1),
            store.statsV1().native_store_bytes,
            &sweep_grant_hex,
            &plan_hex,
            &prepare_hex,
            &commit_grant_hex,
            &targets_hex,
            &store_commit_hex,
            &commit_hex,
            &before_hex,
            &after_hex,
        },
    );
    try stdout.flush();
}

fn demoCapsuleConfig() capsule.ConfigV1 {
    return .{
        .execution_abi = 0x4341_4558_0000_0001,
        .request_epoch = 0x4341_5251_0000_0001,
        .publication_sequence = 5,
        .checkpoint_generation = 0,
        .kv_tokens = 37,
        .output_tokens = 5,
        .challenge_sha256 = [_]u8{0xa8} ** 32,
    };
}

fn demoObjects() capsule.ObjectsV1 {
    return .{
        .model = .{ .abi_version = 0x4341_4d4f_0000_0001, .bytes = "shared-static-identity-v1" },
        .tokenizer = .{ .abi_version = 0x4341_544b_0000_0001, .bytes = "shared-static-identity-v1" },
        .execution_plan = .{ .abi_version = 0x4341_504c_0000_0001, .bytes = "plan-v1:cpu:threads=4:strict" },
        .resource_state = .{ .abi_version = 0x4341_5253_0000_0001, .bytes = "resource-v1:bank=17:kv=4096:output=64" },
        .lane_state = .{ .abi_version = 0x4341_4c4e_0000_0001, .bytes = "lane-v1:request=41:service=11" },
        .kv_state = .{ .abi_version = 0x4341_4b56_0000_0001, .bytes = "kv-v1:positions=37:root=bundle" },
        .sampler_state = .{ .abi_version = 0x4341_534d_0000_0001, .bytes = "sampler-v1:rng=01020304:calls=5" },
        .output_state = .{ .abi_version = 0x4341_4f55_0000_0001, .bytes = "output-v1:tokens=901,902,903,904,905" },
        .publication_receipt = .{ .abi_version = 0x4341_5052_0000_0001, .bytes = "publication-v1:sequence=5:commit=bundle" },
    };
}

fn demoStoreGrant(bundle_sha256: capsule.Digest) object_store.GrantV1 {
    return .{
        .authority_epoch = 11,
        .tenant_scope_sha256 = [_]u8{0x6d} ** 32,
        .bundle_sha256 = bundle_sha256,
        .allowed_operation_mask = object_store.allowed_operations,
        .max_entries = 12,
        .max_object_bytes = 64,
        .max_payload_bytes = 512,
        .max_index_bytes = 12 * object_store.logical_index_entry_bytes,
        .max_references = 16,
        .challenge_sha256 = [_]u8{0xf2} ** 32,
    };
}

fn demoLifecycleGrant(
    store_grant: object_store.GrantV1,
    store_grant_sha256: capsule.Digest,
) object_store.LifecycleGrantV1 {
    return .{
        .authority_epoch = store_grant.authority_epoch,
        .tenant_scope_sha256 = store_grant.tenant_scope_sha256,
        .bundle_sha256 = store_grant.bundle_sha256,
        .store_grant_sha256 = store_grant_sha256,
        .allowed_operation_mask = object_store.allowed_lease_operations,
        .max_active_leases = 4,
        .max_lease_span_ticks = 64,
        .challenge_sha256 = [_]u8{0xc4} ** 32,
    };
}
