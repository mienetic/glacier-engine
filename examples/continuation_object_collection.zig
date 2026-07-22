//! Model-free reachability and dry-run collection-plan demonstration.

const std = @import("std");
const core = @import("core");
const capsule = core.continuation_capsule;
const bundle = core.continuation_bundle;
const object_store = core.continuation_object_store;

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
    const kv: bundle.BlobRefV1 = .{
        .byte_length = kv_entry.byte_length,
        .sha256 = kv_entry.blob_sha256,
    };
    try store.retireV1(kv);
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
    const receipt = try store.planCollectionV1(
        collection_grant,
        &roots,
        &leases,
        &decisions,
    );
    const snapshot_after = try store.auditSnapshotRootV2();
    if (!std.mem.eql(u8, &snapshot_before, &snapshot_after))
        return error.DryRunMutatedStore;
    if (receipt.collectible_bytes != kv.byte_length or fba.end_index != 255)
        return error.CollectionAccountingMismatch;

    const grant_hex = std.fmt.bytesToHex(
        receipt.collection_grant_sha256,
        .lower,
    );
    const roots_hex = std.fmt.bytesToHex(
        receipt.root_references_sha256,
        .lower,
    );
    const leases_hex = std.fmt.bytesToHex(
        receipt.lease_receipts_sha256,
        .lower,
    );
    const snapshot_hex = std.fmt.bytesToHex(receipt.snapshot_sha256, .lower);
    const plan_hex = std.fmt.bytesToHex(receipt.plan_sha256, .lower);
    var stdout_buffer: [3072]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.continuation-object-collection/demo-v1\"," ++
            "\"slot_scans\":{d},\"occupied_entries\":{d}," ++
            "\"root_references\":{d},\"lease_receipts\":{d}," ++
            "\"reachable_entries\":{d},\"reachable_references\":{d}," ++
            "\"leased_entries\":{d},\"leased_references\":{d}," ++
            "\"quarantined_entries\":{d}," ++
            "\"quarantined_references\":{d}," ++
            "\"collectible_entries\":{d},\"collectible_bytes\":{d}," ++
            "\"retained_payload_bytes\":{d},\"payload_bytes_freed\":0," ++
            "\"native_store_bytes\":{d},\"dry_run\":true," ++
            "\"canonical_root_multiplicity\":true," ++
            "\"complete_lease_coverage\":true," ++
            "\"filesystem_authority\":false," ++
            "\"network_authority\":false,\"clock_authority\":false," ++
            "\"collection_grant_sha256\":\"{s}\"," ++
            "\"root_references_sha256\":\"{s}\"," ++
            "\"lease_receipts_sha256\":\"{s}\"," ++
            "\"snapshot_sha256\":\"{s}\"," ++
            "\"plan_sha256\":\"{s}\",\"verified\":true}}\n",
        .{
            receipt.slot_scans,
            receipt.occupied_entries,
            receipt.root_reference_count,
            receipt.lease_receipt_count,
            receipt.reachable_entries,
            receipt.reachable_references,
            receipt.leased_entries,
            receipt.leased_references,
            receipt.quarantined_entries,
            receipt.quarantined_references,
            receipt.collectible_entries,
            receipt.collectible_bytes,
            store.payload_bytes,
            store.statsV1().native_store_bytes,
            &grant_hex,
            &roots_hex,
            &leases_hex,
            &snapshot_hex,
            &plan_hex,
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
