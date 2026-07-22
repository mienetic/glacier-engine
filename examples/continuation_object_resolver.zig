//! Model-free least-authority continuation object resolution demonstration.

const std = @import("std");
const core = @import("core");
const capsule = core.continuation_capsule;
const object_resolver = core.continuation_object_resolver;

pub fn main() !void {
    const config = demoConfig();
    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    const capsule_wire = try capsule.encodeV1(
        config,
        objects,
        &capsule_storage,
    );
    const capsule_root = try capsule.envelopeRootV1(capsule_wire);
    const grant = demoGrant(capsule_root, objects);
    const catalog = try buildCatalog(objects, grant.tenant_scope_sha256);
    var resolver = try object_resolver.ResolverV1.initV1(
        grant,
        grant.authority_epoch,
        capsule_wire,
        &catalog,
    );
    var outputs: [capsule.object_count][64]u8 = undefined;
    for (capsule.object_kinds, 0..) |kind, index| {
        _ = try resolver.resolveV1(kind, &outputs[index]);
    }
    const resolved_objects = try resolver.finishFullV1();
    if (!std.mem.eql(
        u8,
        resolved_objects.kv_state.bytes,
        objects.kv_state.bytes,
    )) return error.ResolvedKvMismatch;

    const grant_root_hex = std.fmt.bytesToHex(
        try object_resolver.grantRootV1(grant),
        .lower,
    );
    if (!std.mem.eql(
        u8,
        &grant_root_hex,
        "d3609c14ddc29235c74f5b1163fff3f4" ++
            "694dd9d0607d30610e5d87bbccc0d2d8",
    )) return error.GoldenGrantMismatch;

    const foreign_catalog = try buildCatalog(objects, [_]u8{0x91} ** 32);
    var foreign_resolver = try object_resolver.ResolverV1.initV1(
        grant,
        grant.authority_epoch,
        capsule_wire,
        &foreign_catalog,
    );
    var foreign_output: [64]u8 = undefined;
    const cross_tenant_rejected = if (foreign_resolver.resolveV1(
        .model,
        &foreign_output,
    )) |_| false else |err| err == error.ObjectNotFound;
    if (!cross_tenant_rejected) return error.CrossTenantObjectAccepted;

    var capsule_root_hex = std.fmt.bytesToHex(capsule_root, .lower);
    var stdout_buffer: [1536]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.continuation-object-resolver/demo-v1\"," ++
            "\"authorized_kind_count\":{d},\"catalog_entries\":{d}," ++
            "\"max_catalog_entries\":{d}," ++
            "\"max_object_bytes\":{d},\"max_total_bytes\":{d}," ++
            "\"resolved_payload_bytes\":{d},\"resolution_count\":{d}," ++
            "\"cross_tenant_rejected\":true," ++
            "\"allocation_free_native\":true," ++
            "\"filesystem_authority\":false," ++
            "\"network_authority\":false," ++
            "\"capsule_sha256\":\"{s}\",\"grant_sha256\":\"{s}\"," ++
            "\"verified\":true}}\n",
        .{
            @popCount(grant.allowed_kind_mask),
            catalog.len,
            grant.max_catalog_entries,
            grant.max_object_bytes,
            grant.max_total_bytes,
            resolver.resolved_bytes,
            resolver.resolution_count,
            &capsule_root_hex,
            &grant_root_hex,
        },
    );
    try stdout.flush();
}

fn demoConfig() capsule.ConfigV1 {
    return .{
        .execution_abi = 0x4341_4558_0000_0001,
        .request_epoch = 0x4341_5251_0000_0001,
        .publication_sequence = 3,
        .checkpoint_generation = 0,
        .kv_tokens = 35,
        .output_tokens = 3,
        .challenge_sha256 = [_]u8{0xa7} ** 32,
    };
}

fn demoObjects() capsule.ObjectsV1 {
    return .{
        .model = .{ .abi_version = 0x4341_4d4f_0000_0001, .bytes = "model-v1:sha256:demo-glrt" },
        .tokenizer = .{ .abi_version = 0x4341_544b_0000_0001, .bytes = "tokenizer-v1:demo-qwen" },
        .execution_plan = .{ .abi_version = 0x4341_504c_0000_0001, .bytes = "plan-v1:cpu:threads=4:strict" },
        .resource_state = .{ .abi_version = 0x4341_5253_0000_0001, .bytes = "resource-v1:bank=17:kv=4096:output=64" },
        .lane_state = .{ .abi_version = 0x4341_4c4e_0000_0001, .bytes = "lane-v1:request=41:service=9" },
        .kv_state = .{ .abi_version = 0x4341_4b56_0000_0001, .bytes = "kv-v1:positions=35:root=demo" },
        .sampler_state = .{ .abi_version = 0x4341_534d_0000_0001, .bytes = "sampler-v1:rng=01020304:calls=3" },
        .output_state = .{ .abi_version = 0x4341_4f55_0000_0001, .bytes = "output-v1:tokens=901,902,903" },
        .publication_receipt = .{ .abi_version = 0x4341_5052_0000_0001, .bytes = "publication-v1:sequence=3:commit=demo" },
    };
}

fn demoGrant(
    capsule_sha256: capsule.Digest,
    objects: capsule.ObjectsV1,
) object_resolver.GrantV1 {
    return .{
        .authority_epoch = 7,
        .request_epoch = demoConfig().request_epoch,
        .capsule_sha256 = capsule_sha256,
        .tenant_scope_sha256 = [_]u8{0x5c} ** 32,
        .allowed_kind_mask = object_resolver.full_object_mask,
        .max_object_bytes = 64,
        .max_total_bytes = objectPayloadBytes(objects),
        .max_resolutions = capsule.object_count,
        .max_catalog_entries = 16,
        .challenge_sha256 = [_]u8{0xd4} ** 32,
    };
}

fn buildCatalog(
    objects: capsule.ObjectsV1,
    tenant_scope_sha256: capsule.Digest,
) ![capsule.object_count]object_resolver.StoredObjectV1 {
    var catalog: [capsule.object_count]object_resolver.StoredObjectV1 = undefined;
    for (capsule.object_kinds, 0..) |kind, index| {
        const object = objects.get(kind);
        const object_ref = try capsule.objectRefV1(kind, object);
        catalog[index] = .{
            .tenant_scope_sha256 = tenant_scope_sha256,
            .kind = kind,
            .abi_version = object.abi_version,
            .sha256 = object_ref.sha256,
            .bytes = object.bytes,
        };
    }
    return catalog;
}

fn objectPayloadBytes(objects: capsule.ObjectsV1) u64 {
    var total: u64 = 0;
    for (capsule.object_kinds) |kind| total += objects.get(kind).bytes.len;
    return total;
}
