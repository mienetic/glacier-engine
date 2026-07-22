//! Model-free bounded tenant continuation object-store demonstration.

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
    const bundle_config = demoBundleConfig(
        try capsule.envelopeRootV1(capsule_wire),
    );
    var bundle_storage: [bundle.encoded_bytes]u8 = undefined;
    const bundle_wire = try bundle.encodeV1(
        bundle_config,
        capsule_wire,
        objects,
        &bundle_storage,
    );
    const bundle_root = try bundle.envelopeRootV1(bundle_wire);
    const grant = demoGrant(bundle_root);
    const grant_root = try object_store.grantRootV1(grant);
    const grant_root_hex = std.fmt.bytesToHex(
        grant_root,
        .lower,
    );
    if (!std.mem.eql(
        u8,
        &grant_root_hex,
        "1d7b766cd09f48421c8638916716299c" ++
            "bbe0d7046aa7c24c54b5971c68d91771",
    )) return error.GoldenStoreGrantMismatch;

    var allocator_storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_storage);
    var store = try object_store.Store.initV1(
        fba.allocator(),
        grant,
        grant.authority_epoch,
    );
    defer store.deinit();
    const receipt = try store.importBundleV1(
        bundle_wire,
        bundle_config,
        capsule_wire,
        objects,
    );
    const snapshot_root_hex = std.fmt.bytesToHex(
        receipt.snapshot_sha256,
        .lower,
    );
    if (!std.mem.eql(
        u8,
        &snapshot_root_hex,
        "5ef533c5bbf2db216806736f6a12c595" ++
            "03f668b02e3c12dba8dc8b503121860f",
    )) return error.GoldenStoreSnapshotMismatch;
    const decoded_bundle = try bundle.decodeManifestV1(bundle_wire);
    const model = decoded_bundle.entry(.model);
    var output: [64]u8 = undefined;
    const resolved = try store.getV1(.{
        .byte_length = model.byte_length,
        .sha256 = model.blob_sha256,
    }, &output);
    if (!std.mem.eql(u8, resolved, objects.model.bytes))
        return error.StoredPayloadMismatch;
    const lifecycle_grant = demoLifecycleGrant(grant, grant_root);
    const lifecycle_grant_root = try object_store.lifecycleGrantRootV1(
        lifecycle_grant,
    );
    const lifecycle_grant_hex = std.fmt.bytesToHex(
        lifecycle_grant_root,
        .lower,
    );
    if (!std.mem.eql(
        u8,
        &lifecycle_grant_hex,
        "cfd5df486b00f6fcf2fb61792a49bd4c" ++
            "4ad358be183b9ec2b4df517a4b79b85b",
    )) return error.GoldenLifecycleGrantMismatch;
    const model_key: bundle.BlobRefV1 = .{
        .byte_length = model.byte_length,
        .sha256 = model.blob_sha256,
    };
    const first_lease = try store.acquireLeaseV1(
        model_key,
        lifecycle_grant,
        [_]u8{0x71} ** 32,
        100,
        120,
    );
    const renewed_lease = try store.renewLeaseV1(
        model_key,
        first_lease,
        lifecycle_grant,
        110,
        150,
    );
    try store.releaseLeaseV1(
        model_key,
        renewed_lease,
        lifecycle_grant,
    );
    const kv_entry = decoded_bundle.entry(.kv_state);
    const kv_key: bundle.BlobRefV1 = .{
        .byte_length = kv_entry.byte_length,
        .sha256 = kv_entry.blob_sha256,
    };
    const kv_lease = try store.acquireLeaseV1(
        kv_key,
        lifecycle_grant,
        [_]u8{0x72} ** 32,
        200,
        240,
    );
    const quarantine_reason = [_]u8{0x9a} ** 32;
    const repair_source = [_]u8{0xb6} ** 32;
    try store.quarantineV1(kv_key, quarantine_reason);
    const repair_grant = demoRepairGrant(
        grant,
        grant_root,
        kv_key,
        repair_source,
        quarantine_reason,
    );
    const repair_grant_root = try object_store.repairGrantRootV1(
        repair_grant,
    );
    const repair_grant_hex = std.fmt.bytesToHex(repair_grant_root, .lower);
    const repair = try store.repairV1(
        kv_key,
        objects.kv_state.bytes,
        repair_source,
        repair_grant,
    );
    const repair_hex = std.fmt.bytesToHex(repair.repair_sha256, .lower);
    const lifecycle_snapshot = try store.snapshotRootV2();
    const lifecycle_snapshot_hex = std.fmt.bytesToHex(
        lifecycle_snapshot,
        .lower,
    );
    if (!std.mem.eql(
        u8,
        &lifecycle_snapshot_hex,
        "239ea7e7555388fab740d3d1fdb8040a" ++
            "7f3706b102e9572c05f7dc612822e1bd",
    )) return error.GoldenLifecycleSnapshotMismatch;
    try store.verifyAllV1();
    const stats = store.statsV1();
    if (fba.end_index != stats.payload_bytes)
        return error.AllocatorAccountingMismatch;

    const bundle_root_hex = std.fmt.bytesToHex(bundle_root, .lower);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.continuation-object-store/demo-v1\"," ++
            "\"semantic_references\":{d},\"unique_entries\":{d}," ++
            "\"references_reused\":{d},\"reference_count\":{d}," ++
            "\"naive_payload_bytes\":{d},\"allocated_payload_bytes\":{d}," ++
            "\"duplicate_payload_bytes_avoided\":{d}," ++
            "\"allocator_consumed_bytes\":{d}," ++
            "\"allocator_backing_capacity_bytes\":{d}," ++
            "\"logical_index_bytes\":{d}," ++
            "\"native_slot_capacity_bytes\":{d}," ++
            "\"native_store_bytes\":{d}," ++
            "\"active_leases\":{d},\"repair_count\":{d}," ++
            "\"renewed_lease_generation\":{d}," ++
            "\"quarantine_fenced_generation\":{d}," ++
            "\"repair_generation\":{d}," ++
            "\"atomic_import\":true,\"tenant_scoped\":true," ++
            "\"generation_fenced_leases\":true," ++
            "\"provenance_aware_repair\":true," ++
            "\"ambient_clock_authority\":false," ++
            "\"corruption_verification\":true," ++
            "\"filesystem_authority\":false," ++
            "\"network_authority\":false," ++
            "\"net_memory_savings_measured\":false," ++
            "\"bundle_sha256\":\"{s}\",\"grant_sha256\":\"{s}\"," ++
            "\"snapshot_sha256\":\"{s}\"," ++
            "\"lifecycle_grant_sha256\":\"{s}\"," ++
            "\"repair_grant_sha256\":\"{s}\"," ++
            "\"repair_receipt_sha256\":\"{s}\"," ++
            "\"lifecycle_snapshot_sha256\":\"{s}\"," ++
            "\"verified\":true}}\n",
        .{
            receipt.semantic_references,
            stats.entry_count,
            receipt.references_reused,
            stats.reference_count,
            decoded_bundle.logical_payload_bytes,
            stats.payload_bytes,
            decoded_bundle.deduplicatedPayloadBytes(),
            fba.end_index,
            allocator_storage.len,
            stats.logical_index_bytes,
            stats.native_slot_capacity_bytes,
            stats.native_store_bytes,
            stats.active_leases,
            stats.repair_count,
            renewed_lease.generation,
            kv_lease.generation,
            repair.repair_generation,
            &bundle_root_hex,
            &grant_root_hex,
            &snapshot_root_hex,
            &lifecycle_grant_hex,
            &repair_grant_hex,
            &repair_hex,
            &lifecycle_snapshot_hex,
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

fn demoBundleConfig(capsule_sha256: capsule.Digest) bundle.ConfigV1 {
    return .{
        .tenant_scope_sha256 = [_]u8{0x6d} ** 32,
        .capsule_sha256 = capsule_sha256,
        .bundle_generation = 0,
        .challenge_sha256 = [_]u8{0xe3} ** 32,
    };
}

fn demoGrant(bundle_sha256: capsule.Digest) object_store.GrantV1 {
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

fn demoRepairGrant(
    store_grant: object_store.GrantV1,
    store_grant_sha256: capsule.Digest,
    target: bundle.BlobRefV1,
    source_provenance_sha256: capsule.Digest,
    quarantine_reason_sha256: capsule.Digest,
) object_store.RepairGrantV1 {
    return .{
        .authority_epoch = store_grant.authority_epoch,
        .tenant_scope_sha256 = store_grant.tenant_scope_sha256,
        .bundle_sha256 = store_grant.bundle_sha256,
        .store_grant_sha256 = store_grant_sha256,
        .target = target,
        .trusted_source_sha256 = source_provenance_sha256,
        .expected_quarantine_reason_sha256 = quarantine_reason_sha256,
        .max_repair_bytes = 64,
        .challenge_sha256 = [_]u8{0xd7} ** 32,
    };
}
