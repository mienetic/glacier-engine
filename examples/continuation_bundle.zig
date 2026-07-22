//! Model-free canonical tenant-scoped continuation bundle demonstration.

const std = @import("std");
const core = @import("core");
const capsule = core.continuation_capsule;
const bundle = core.continuation_bundle;

pub fn main() !void {
    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    const capsule_wire = try capsule.encodeV1(
        demoCapsuleConfig(),
        objects,
        &capsule_storage,
    );
    const config = demoBundleConfig(try capsule.envelopeRootV1(capsule_wire));
    var bundle_storage: [bundle.encoded_bytes]u8 = undefined;
    const encoded = try bundle.encodeV1(
        config,
        capsule_wire,
        objects,
        &bundle_storage,
    );
    const decoded = try bundle.decodeAndVerifyV1(
        encoded,
        config,
        capsule_wire,
        objects,
    );
    const bundle_root_hex = std.fmt.bytesToHex(
        decoded.envelope_sha256,
        .lower,
    );
    if (!std.mem.eql(
        u8,
        &bundle_root_hex,
        "390c29d58b4cf979f44606f611f10b81" ++
            "1351d85cdbe1dedaeebe7b31b8564cc5",
    )) return error.GoldenBundleMismatch;
    if (decoded.entry(.model).blob_ordinal !=
        decoded.entry(.tokenizer).blob_ordinal)
        return error.DuplicatePayloadNotCanonical;
    if (std.mem.eql(
        u8,
        &decoded.entry(.model).typed_sha256,
        &decoded.entry(.tokenizer).typed_sha256,
    )) return error.TypedDomainsCollapsed;

    const first_blob = try bundle.blobRefV1(
        config.tenant_scope_sha256,
        objects.model.bytes,
    );
    const foreign_blob = try bundle.blobRefV1(
        [_]u8{0x7e} ** 32,
        objects.model.bytes,
    );
    if (std.mem.eql(u8, &first_blob.sha256, &foreign_blob.sha256))
        return error.TenantBlobIdentityCollapsed;

    const capsule_root_hex = std.fmt.bytesToHex(
        config.capsule_sha256,
        .lower,
    );
    var stdout_buffer: [1536]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.continuation-bundle/demo-v1\"," ++
            "\"bundle_wire_bytes\":{d},\"capsule_wire_bytes\":{d}," ++
            "\"object_entries\":{d},\"unique_blob_count\":{d}," ++
            "\"logical_payload_bytes\":{d},\"unique_blob_bytes\":{d}," ++
            "\"deduplicated_payload_bytes\":{d}," ++
            "\"payload_bytes_embedded\":0," ++
            "\"canonical_ordinals\":true," ++
            "\"tenant_blob_isolation\":true," ++
            "\"allocation_free_native\":true," ++
            "\"filesystem_authority\":false," ++
            "\"storage_writes\":false," ++
            "\"physical_storage_savings_measured\":false," ++
            "\"capsule_sha256\":\"{s}\",\"bundle_sha256\":\"{s}\"," ++
            "\"verified\":true}}\n",
        .{
            encoded.len,
            capsule_wire.len,
            capsule.object_count,
            decoded.unique_blob_count,
            decoded.logical_payload_bytes,
            decoded.unique_blob_bytes,
            decoded.deduplicatedPayloadBytes(),
            &capsule_root_hex,
            &bundle_root_hex,
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
