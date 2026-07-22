//! Model-free proof-carrying AI continuation capsule demonstration.

const std = @import("std");
const capsule = @import("core").continuation_capsule;

pub fn main() !void {
    const config = demoConfig();
    const objects = demoObjects();
    var storage: [capsule.encoded_bytes]u8 = undefined;
    const encoded = try capsule.encodeV1(config, objects, &storage);
    const decoded = try capsule.decodeAndVerifyV1(
        encoded,
        config,
        objects,
    );

    var foreign = objects;
    foreign.kv_state = .{
        .abi_version = objects.kv_state.abi_version,
        .bytes = "kv-v1:positions=35:root=foreign",
    };
    const substitution_rejected = if (capsule.decodeAndVerifyV1(
        encoded,
        config,
        foreign,
    )) |_| false else |_| true;
    if (!substitution_rejected) return error.ForeignObjectAccepted;

    const root_hex = std.fmt.bytesToHex(
        decoded.envelope_sha256,
        .lower,
    );
    if (!std.mem.eql(
        u8,
        &root_hex,
        "b03dfe6cc29b64da03377a2d0cf1b576" ++
            "35f04d4fe8a2ffa1a8497cb8e55e1aeb",
    )) return error.GoldenCapsuleMismatch;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.continuation-capsule/demo-v1\"," ++
            "\"capsule_wire_bytes\":{d},\"bound_objects\":{d}," ++
            "\"external_object_payload_bytes\":{d}," ++
            "\"payload_bytes_embedded\":0," ++
            "\"publication_sequence\":{d}," ++
            "\"checkpoint_generation\":{d}," ++
            "\"kv_tokens\":{d},\"output_tokens\":{d}," ++
            "\"object_substitution_rejected\":true," ++
            "\"filesystem_authority\":false," ++
            "\"verified\":true," ++
            "\"capsule_sha256\":\"{s}\"}}\n",
        .{
            encoded.len,
            capsule.object_count,
            objectPayloadBytes(objects),
            config.publication_sequence,
            config.checkpoint_generation,
            config.kv_tokens,
            config.output_tokens,
            &root_hex,
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

fn objectPayloadBytes(objects: capsule.ObjectsV1) usize {
    var total: usize = 0;
    for (capsule.object_kinds) |kind| total += objects.get(kind).bytes.len;
    return total;
}
