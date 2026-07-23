//! Capability-scoped collection sweep prepare/abort demonstration.

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
    const kv_entry = decoded.entry(.kv_state);
    try store.retireV1(.{
        .byte_length = kv_entry.byte_length,
        .sha256 = kv_entry.blob_sha256,
    });
    const lane_entry = decoded.entry(.lane_state);
    try store.quarantineV1(.{
        .byte_length = lane_entry.byte_length,
        .sha256 = lane_entry.blob_sha256,
    }, [_]u8{0x9a} ** 32);

    var roots: [capsule.object_count - 1]bundle.BlobRefV1 = undefined;
    var root_count: usize = 0;
    for (capsule.object_kinds) |kind| {
        if (kind == .kv_state) continue;
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
    const empty_journal: sweep.JournalV1 = .{};
    const prepared = try sweep.prepareV1(
        &store,
        sweep_grant,
        collection_grant,
        &roots,
        &leases,
        empty_journal,
    );
    const aborted = try sweep.abortV1(
        &store,
        sweep_grant,
        prepared.journal,
    );
    try sweep.verifyJournalV1(sweep_grant, aborted.journal);
    const snapshot_after = try store.auditSnapshotRootV2();
    if (!std.mem.eql(u8, &snapshot_before, &snapshot_after))
        return error.SweepJournalMutatedStore;
    if (store.payload_bytes != 255 or fba.end_index != 255)
        return error.SweepJournalFreedPayload;
    if (empty_journal.state != .empty)
        return error.InputJournalMutated;

    const grant_hex = std.fmt.bytesToHex(
        prepared.receipt.sweep_grant_sha256,
        .lower,
    );
    const plan_hex = std.fmt.bytesToHex(
        prepared.receipt.collection_plan_sha256,
        .lower,
    );
    const snapshot_hex = std.fmt.bytesToHex(
        prepared.receipt.snapshot_sha256,
        .lower,
    );
    const prepare_hex = std.fmt.bytesToHex(
        prepared.receipt.prepare_sha256,
        .lower,
    );
    const abort_hex = std.fmt.bytesToHex(
        aborted.receipt.abort_sha256,
        .lower,
    );
    var stdout_buffer: [3072]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.continuation-object-sweep/demo-v1\"," ++
            "\"journal_state\":\"aborted\",\"journal_bytes\":{d}," ++
            "\"native_store_bytes\":{d},\"sweep_heap_allocations\":0," ++
            "\"revalidation_slot_scans\":{d}," ++
            "\"staged_entries\":{d},\"staged_bytes\":{d}," ++
            "\"retained_payload_bytes\":{d},\"payload_bytes_freed\":0," ++
            "\"store_snapshot_unchanged\":true," ++
            "\"input_journal_unchanged\":true," ++
            "\"functional_transitions\":true," ++
            "\"collection_plan_regenerated\":true," ++
            "\"filesystem_authority\":false," ++
            "\"network_authority\":false,\"clock_authority\":false," ++
            "\"deallocation_authority\":false," ++
            "\"sweep_grant_sha256\":\"{s}\"," ++
            "\"collection_plan_sha256\":\"{s}\"," ++
            "\"snapshot_sha256\":\"{s}\"," ++
            "\"prepare_sha256\":\"{s}\"," ++
            "\"abort_sha256\":\"{s}\",\"verified\":true}}\n",
        .{
            @sizeOf(sweep.JournalV1),
            store.statsV1().native_store_bytes,
            prepared.collection_receipt.slot_scans,
            prepared.receipt.staged_entries,
            prepared.receipt.staged_bytes,
            store.payload_bytes,
            &grant_hex,
            &plan_hex,
            &snapshot_hex,
            &prepare_hex,
            &abort_hex,
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
