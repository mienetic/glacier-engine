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
    const grant_root_hex = std.fmt.bytesToHex(
        try object_store.grantRootV1(grant),
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
    try store.verifyAllV1();
    const stats = store.statsV1();
    if (fba.end_index != stats.payload_bytes)
        return error.AllocatorAccountingMismatch;

    const bundle_root_hex = std.fmt.bytesToHex(bundle_root, .lower);
    var stdout_buffer: [2048]u8 = undefined;
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
            "\"atomic_import\":true,\"tenant_scoped\":true," ++
            "\"corruption_verification\":true," ++
            "\"filesystem_authority\":false," ++
            "\"network_authority\":false," ++
            "\"net_memory_savings_measured\":false," ++
            "\"bundle_sha256\":\"{s}\",\"grant_sha256\":\"{s}\"," ++
            "\"snapshot_sha256\":\"{s}\",\"verified\":true}}\n",
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
            &bundle_root_hex,
            &grant_root_hex,
            &snapshot_root_hex,
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
