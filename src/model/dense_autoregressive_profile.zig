const std = @import("std");
const package_manifest = @import("package_manifest.zig");
const safetensors = @import("safetensors.zig");

pub const tensor_profile_abi_v1: u64 = 0x474c545000000001;
pub const conversion_architecture_v1 = "glacier-ordinary-package-v1";
pub const maximum_layers_v1: u32 = 512;
pub const minimum_vocabulary_v1: u32 = 256;

const inventory_domain_v1 =
    "glacier/ordinary-package/tensor-inventory/v1\x00";
const global_layer_v1 = std.math.maxInt(u32);
const required_global_mask_v1: u8 = 0b111;
const required_layer_mask_v1: u16 = (1 << 9) - 1;

pub const Error = error{
    InvalidSource,
    SourceReadFailed,
    UnsupportedConfigProfile,
    UnsupportedTensorProfile,
    ResourceLimit,
    OutOfMemory,
};

pub const InventoryReceiptV1 = struct {
    profile_abi: u64 = tensor_profile_abi_v1,
    tensor_count: u64,
    inventory_sha256: [32]u8,
};

/// Return the canonical inventory identity implied by one exact supported
/// configuration without reading a source descriptor.
pub fn expectedInventoryV1(
    config: package_manifest.ConfigV1,
) Error!InventoryReceiptV1 {
    try validateConfigV1(config);
    const layer_tensor_count = std.math.mul(
        u64,
        config.layers,
        9,
    ) catch return Error.ResourceLimit;
    const tensor_count = std.math.add(
        u64,
        layer_tensor_count,
        3,
    ) catch return Error.ResourceLimit;
    return .{
        .tensor_count = tensor_count,
        .inventory_sha256 = inventorySha256V1(
            config,
            tensor_count,
        ),
    };
}

const InventoryRoleV1 = enum(u8) {
    embedding = 1,
    final_norm = 2,
    lm_head = 3,
    input_norm = 4,
    attn_q = 5,
    attn_k = 6,
    attn_v = 7,
    attn_o = 8,
    post_attn_norm = 9,
    mlp_gate = 10,
    mlp_up = 11,
    mlp_down = 12,
};

const LayerRoleV1 = enum(u4) {
    input_norm = 0,
    attn_q = 1,
    attn_k = 2,
    attn_v = 3,
    attn_o = 4,
    post_attn_norm = 5,
    mlp_gate = 6,
    mlp_up = 7,
    mlp_down = 8,
};

/// Validate the exact, currently supported ordinary-package tensor profile
/// against a source descriptor that the caller already captured. This helper
/// uses positional reads only and does not change the descriptor position or
/// any filesystem namespace.
pub fn validateCapturedSourceV1(
    allocator: std.mem.Allocator,
    file: *std.fs.File,
    source_bytes: u64,
    config: package_manifest.ConfigV1,
) Error!InventoryReceiptV1 {
    try validateConfigV1(config);
    if (source_bytes < @sizeOf(u64))
        return Error.InvalidSource;

    var length_bytes: [@sizeOf(u64)]u8 = undefined;
    const length_read = file.preadAll(&length_bytes, 0) catch
        return Error.SourceReadFailed;
    if (length_read != length_bytes.len)
        return Error.InvalidSource;
    const header_bytes = std.mem.readInt(
        u64,
        &length_bytes,
        .little,
    );
    if (header_bytes > safetensors.MAX_HEADER_BYTES)
        return Error.ResourceLimit;
    const prefix_bytes_u64 = std.math.add(
        u64,
        @sizeOf(u64),
        header_bytes,
    ) catch return Error.InvalidSource;
    if (prefix_bytes_u64 > source_bytes)
        return Error.InvalidSource;
    const prefix_bytes = std.math.cast(
        usize,
        prefix_bytes_u64,
    ) orelse return Error.ResourceLimit;
    const prefix = allocator.alloc(u8, prefix_bytes) catch
        return Error.OutOfMemory;
    defer allocator.free(prefix);
    const prefix_read = file.preadAll(prefix, 0) catch
        return Error.SourceReadFailed;
    if (prefix_read != prefix.len)
        return Error.SourceReadFailed;

    var parsed = safetensors.parseHeaderPrefix(
        allocator,
        prefix,
        source_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        error.HeaderTooLarge => return Error.ResourceLimit,
        else => return Error.InvalidSource,
    };
    defer parsed.deinit();

    // The shared parser validates Safetensors framing and byte coverage. The
    // profile additionally requires duplicate-free JSON and exact descriptor
    // fields so an overwritten key cannot masquerade as one admitted tensor.
    try validateStrictDescriptorsV1(allocator, parsed.header_json);
    return validateInventoryV1(
        allocator,
        parsed.tensors,
        config,
    );
}

fn validateStrictDescriptorsV1(
    allocator: std.mem.Allocator,
    header_json: []const u8,
) Error!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        header_json,
        .{ .duplicate_field_behavior = .@"error" },
    ) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.InvalidSource,
    };
    if (value != .object)
        return Error.InvalidSource;
    var entries = value.object.iterator();
    while (entries.next()) |entry| {
        if (std.mem.eql(
            u8,
            entry.key_ptr.*,
            "__metadata__",
        )) continue;
        if (entry.value_ptr.* != .object)
            return Error.InvalidSource;
        var descriptor_fields: usize = 0;
        var fields = entry.value_ptr.*.object.iterator();
        while (fields.next()) |field| {
            const key = field.key_ptr.*;
            if (!std.mem.eql(u8, key, "dtype") and
                !std.mem.eql(u8, key, "shape") and
                !std.mem.eql(u8, key, "data_offsets"))
            {
                return Error.UnsupportedTensorProfile;
            }
            descriptor_fields += 1;
        }
        if (descriptor_fields != 3)
            return Error.InvalidSource;
    }
}

fn validateConfigV1(
    config: package_manifest.ConfigV1,
) Error!void {
    if (config.dim == 0 or
        config.hidden_dim == 0 or
        config.layers == 0 or
        config.layers > maximum_layers_v1 or
        config.vocab < minimum_vocabulary_v1 or
        config.heads == 0 or
        config.head_dim == 0 or
        config.kv_heads == 0 or
        config.tie_embeddings or
        !std.math.isFinite(config.rms_eps) or
        config.rms_eps <= 0 or
        !std.math.isFinite(config.rope_theta) or
        config.rope_theta <= 0)
    {
        return Error.UnsupportedConfigProfile;
    }
    const represented_dim = std.math.mul(
        u64,
        config.heads,
        config.head_dim,
    ) catch return Error.UnsupportedConfigProfile;
    if (represented_dim != config.dim or
        config.kv_heads != config.heads)
    {
        return Error.UnsupportedConfigProfile;
    }
}

fn validateInventoryV1(
    allocator: std.mem.Allocator,
    tensors: []const safetensors.TensorInfo,
    config: package_manifest.ConfigV1,
) Error!InventoryReceiptV1 {
    const expected = try expectedInventoryV1(config);
    const expected_tensor_count = std.math.cast(
        usize,
        expected.tensor_count,
    ) orelse return Error.ResourceLimit;
    if (tensors.len != expected_tensor_count)
        return Error.UnsupportedTensorProfile;

    const layer_count = std.math.cast(
        usize,
        config.layers,
    ) orelse return Error.ResourceLimit;
    const layer_masks = allocator.alloc(u16, layer_count) catch
        return Error.OutOfMemory;
    defer allocator.free(layer_masks);
    @memset(layer_masks, 0);
    var global_mask: u8 = 0;

    for (tensors) |tensor| {
        if (tensor.dtype != .f32)
            return Error.UnsupportedTensorProfile;
        if (std.mem.eql(
            u8,
            tensor.name,
            "model.embed_tokens.weight",
        )) {
            try markGlobalV1(&global_mask, 0);
            try requireShapeV1(tensor.shape, &.{
                config.vocab,
                config.dim,
            });
            continue;
        }
        if (std.mem.eql(
            u8,
            tensor.name,
            "model.norm.weight",
        )) {
            try markGlobalV1(&global_mask, 1);
            try requireShapeV1(tensor.shape, &.{config.dim});
            continue;
        }
        if (std.mem.eql(
            u8,
            tensor.name,
            "lm_head.weight",
        )) {
            try markGlobalV1(&global_mask, 2);
            try requireShapeV1(tensor.shape, &.{
                config.vocab,
                config.dim,
            });
            continue;
        }

        const parsed_name = try parseLayerTensorNameV1(
            tensor.name,
            config.layers,
        );
        const layer_index = std.math.cast(
            usize,
            parsed_name.layer,
        ) orelse return Error.ResourceLimit;
        const bit: u16 =
            @as(u16, 1) << @intFromEnum(parsed_name.role);
        if (layer_masks[layer_index] & bit != 0)
            return Error.UnsupportedTensorProfile;
        layer_masks[layer_index] |= bit;
        try requireLayerShapeV1(
            tensor.shape,
            parsed_name.role,
            config,
        );
    }

    if (global_mask != required_global_mask_v1)
        return Error.UnsupportedTensorProfile;
    for (layer_masks) |mask| {
        if (mask != required_layer_mask_v1)
            return Error.UnsupportedTensorProfile;
    }
    return .{
        .tensor_count = expected.tensor_count,
        .inventory_sha256 = expected.inventory_sha256,
    };
}

fn markGlobalV1(mask: *u8, bit_index: u3) Error!void {
    const bit: u8 = @as(u8, 1) << bit_index;
    if (mask.* & bit != 0)
        return Error.UnsupportedTensorProfile;
    mask.* |= bit;
}

const ParsedLayerTensorNameV1 = struct {
    layer: u32,
    role: LayerRoleV1,
};

fn parseLayerTensorNameV1(
    name: []const u8,
    layer_count: u32,
) Error!ParsedLayerTensorNameV1 {
    const prefix = "model.layers.";
    if (!std.mem.startsWith(u8, name, prefix))
        return Error.UnsupportedTensorProfile;
    const suffix_separator = std.mem.indexOfScalarPos(
        u8,
        name,
        prefix.len,
        '.',
    ) orelse return Error.UnsupportedTensorProfile;
    const digits = name[prefix.len..suffix_separator];
    if (digits.len == 0 or
        (digits.len > 1 and digits[0] == '0'))
    {
        return Error.UnsupportedTensorProfile;
    }
    for (digits) |byte| {
        if (!std.ascii.isDigit(byte))
            return Error.UnsupportedTensorProfile;
    }
    const layer = std.fmt.parseInt(
        u32,
        digits,
        10,
    ) catch return Error.UnsupportedTensorProfile;
    if (layer >= layer_count)
        return Error.UnsupportedTensorProfile;
    const suffix = name[suffix_separator + 1 ..];
    const role: LayerRoleV1 =
        if (std.mem.eql(
            u8,
            suffix,
            "input_layernorm.weight",
        ))
            .input_norm
        else if (std.mem.eql(
            u8,
            suffix,
            "self_attn.q_proj.weight",
        ))
            .attn_q
        else if (std.mem.eql(
            u8,
            suffix,
            "self_attn.k_proj.weight",
        ))
            .attn_k
        else if (std.mem.eql(
            u8,
            suffix,
            "self_attn.v_proj.weight",
        ))
            .attn_v
        else if (std.mem.eql(
            u8,
            suffix,
            "self_attn.o_proj.weight",
        ))
            .attn_o
        else if (std.mem.eql(
            u8,
            suffix,
            "post_attention_layernorm.weight",
        ))
            .post_attn_norm
        else if (std.mem.eql(
            u8,
            suffix,
            "mlp.gate_proj.weight",
        ))
            .mlp_gate
        else if (std.mem.eql(
            u8,
            suffix,
            "mlp.up_proj.weight",
        ))
            .mlp_up
        else if (std.mem.eql(
            u8,
            suffix,
            "mlp.down_proj.weight",
        ))
            .mlp_down
        else
            return Error.UnsupportedTensorProfile;
    return .{ .layer = layer, .role = role };
}

fn requireLayerShapeV1(
    actual: []const u64,
    role: LayerRoleV1,
    config: package_manifest.ConfigV1,
) Error!void {
    switch (role) {
        .input_norm, .post_attn_norm => try requireShapeV1(
            actual,
            &.{config.dim},
        ),
        .attn_q, .attn_k, .attn_v, .attn_o => try requireShapeV1(
            actual,
            &.{ config.dim, config.dim },
        ),
        .mlp_gate, .mlp_up => try requireShapeV1(
            actual,
            &.{ config.hidden_dim, config.dim },
        ),
        .mlp_down => try requireShapeV1(
            actual,
            &.{ config.dim, config.hidden_dim },
        ),
    }
}

fn requireShapeV1(
    actual: []const u64,
    expected: []const u64,
) Error!void {
    if (!std.mem.eql(u64, actual, expected))
        return Error.UnsupportedTensorProfile;
}

fn inventorySha256V1(
    config: package_manifest.ConfigV1,
    tensor_count: u64,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(inventory_domain_v1);
    hashU64V1(&hash, tensor_profile_abi_v1);
    hashU64V1(&hash, tensor_count);
    hashU32V1(&hash, config.dim);
    hashU32V1(&hash, config.hidden_dim);
    hashU32V1(&hash, config.layers);
    hashU32V1(&hash, config.vocab);
    hashU32V1(&hash, config.heads);
    hashU32V1(&hash, config.head_dim);
    hashU32V1(&hash, config.kv_heads);

    hashTensorV1(
        &hash,
        global_layer_v1,
        .embedding,
        &.{ config.vocab, config.dim },
    );
    hashTensorV1(
        &hash,
        global_layer_v1,
        .final_norm,
        &.{config.dim},
    );
    hashTensorV1(
        &hash,
        global_layer_v1,
        .lm_head,
        &.{ config.vocab, config.dim },
    );
    var layer: u32 = 0;
    while (layer < config.layers) : (layer += 1) {
        hashTensorV1(
            &hash,
            layer,
            .input_norm,
            &.{config.dim},
        );
        hashTensorV1(
            &hash,
            layer,
            .attn_q,
            &.{ config.dim, config.dim },
        );
        hashTensorV1(
            &hash,
            layer,
            .attn_k,
            &.{ config.dim, config.dim },
        );
        hashTensorV1(
            &hash,
            layer,
            .attn_v,
            &.{ config.dim, config.dim },
        );
        hashTensorV1(
            &hash,
            layer,
            .attn_o,
            &.{ config.dim, config.dim },
        );
        hashTensorV1(
            &hash,
            layer,
            .post_attn_norm,
            &.{config.dim},
        );
        hashTensorV1(
            &hash,
            layer,
            .mlp_gate,
            &.{ config.hidden_dim, config.dim },
        );
        hashTensorV1(
            &hash,
            layer,
            .mlp_up,
            &.{ config.hidden_dim, config.dim },
        );
        hashTensorV1(
            &hash,
            layer,
            .mlp_down,
            &.{ config.dim, config.hidden_dim },
        );
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn hashTensorV1(
    hash: *std.crypto.hash.sha2.Sha256,
    layer: u32,
    role: InventoryRoleV1,
    shape: []const u64,
) void {
    hashU32V1(hash, layer);
    hashU8V1(hash, @intFromEnum(role));
    // F32 is the only admitted source precision in this profile.
    hashU8V1(hash, 1);
    hashU8V1(hash, @intCast(shape.len));
    for (shape) |extent| hashU64V1(hash, extent);
}

fn hashU8V1(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u8,
) void {
    hash.update(&.{value});
}

fn hashU32V1(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u32,
) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashU64V1(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

const testing = std.testing;

fn testConfigV1() package_manifest.ConfigV1 {
    return .{
        .dim = 2,
        .hidden_dim = 3,
        .layers = 1,
        .vocab = minimum_vocabulary_v1,
        .heads = 1,
        .head_dim = 2,
        .kv_heads = 1,
        .rms_eps = 1e-5,
        .rope_theta = 10_000,
        .tie_embeddings = false,
    };
}

fn testTensorV1(
    name: []const u8,
    shape: []const u64,
) safetensors.TensorInfo {
    return .{
        .name = name,
        .dtype = .f32,
        .byte_length = 0,
        .data_offset = 0,
        .shape = shape,
    };
}

fn testInventoryV1() [12]safetensors.TensorInfo {
    return .{
        testTensorV1(
            "model.embed_tokens.weight",
            &.{ minimum_vocabulary_v1, 2 },
        ),
        testTensorV1(
            "model.layers.0.input_layernorm.weight",
            &.{2},
        ),
        testTensorV1(
            "model.layers.0.self_attn.q_proj.weight",
            &.{ 2, 2 },
        ),
        testTensorV1(
            "model.layers.0.self_attn.k_proj.weight",
            &.{ 2, 2 },
        ),
        testTensorV1(
            "model.layers.0.self_attn.v_proj.weight",
            &.{ 2, 2 },
        ),
        testTensorV1(
            "model.layers.0.self_attn.o_proj.weight",
            &.{ 2, 2 },
        ),
        testTensorV1(
            "model.layers.0.post_attention_layernorm.weight",
            &.{2},
        ),
        testTensorV1(
            "model.layers.0.mlp.gate_proj.weight",
            &.{ 3, 2 },
        ),
        testTensorV1(
            "model.layers.0.mlp.up_proj.weight",
            &.{ 3, 2 },
        ),
        testTensorV1(
            "model.layers.0.mlp.down_proj.weight",
            &.{ 2, 3 },
        ),
        testTensorV1("model.norm.weight", &.{2}),
        testTensorV1(
            "lm_head.weight",
            &.{ minimum_vocabulary_v1, 2 },
        ),
    };
}

test "ordinary package profile admits only its exact tensor inventory" {
    const config = testConfigV1();
    const tensors = testInventoryV1();
    const receipt = try validateInventoryV1(
        testing.allocator,
        &tensors,
        config,
    );
    try testing.expectEqual(tensor_profile_abi_v1, receipt.profile_abi);
    try testing.expectEqual(@as(u64, 12), receipt.tensor_count);
    const zero_digest = [_]u8{0} ** 32;
    try testing.expect(!std.mem.eql(
        u8,
        &receipt.inventory_sha256,
        &zero_digest,
    ));
}

test "ordinary package profile inventory identity ignores source order" {
    const config = testConfigV1();
    const tensors = testInventoryV1();
    var reversed: [tensors.len]safetensors.TensorInfo = undefined;
    for (tensors, 0..) |tensor, index|
        reversed[reversed.len - index - 1] = tensor;
    const expected = try validateInventoryV1(
        testing.allocator,
        &tensors,
        config,
    );
    const actual = try validateInventoryV1(
        testing.allocator,
        &reversed,
        config,
    );
    try testing.expectEqualSlices(
        u8,
        &expected.inventory_sha256,
        &actual.inventory_sha256,
    );
}

test "ordinary package profile rejects equal-count transposes and extras" {
    const config = testConfigV1();
    var transposed = testInventoryV1();
    transposed[0].shape = &.{ 2, minimum_vocabulary_v1 };
    try testing.expectError(
        Error.UnsupportedTensorProfile,
        validateInventoryV1(
            testing.allocator,
            &transposed,
            config,
        ),
    );

    const base = testInventoryV1();
    var extra: [13]safetensors.TensorInfo = undefined;
    @memcpy(extra[0..12], &base);
    extra[12] = testTensorV1("model.rotary_emb.inv_freq", &.{2});
    try testing.expectError(
        Error.UnsupportedTensorProfile,
        validateInventoryV1(
            testing.allocator,
            &extra,
            config,
        ),
    );
}

test "ordinary package profile rejects aliases and unsupported config" {
    var alias = testInventoryV1();
    alias[2].name = "transformer.layers.0.self_attn.q_proj.weight";
    try testing.expectError(
        Error.UnsupportedTensorProfile,
        validateInventoryV1(
            testing.allocator,
            &alias,
            testConfigV1(),
        ),
    );

    var tied = testConfigV1();
    tied.tie_embeddings = true;
    try testing.expectError(
        Error.UnsupportedConfigProfile,
        validateConfigV1(tied),
    );
    var gqa = testConfigV1();
    gqa.kv_heads = 2;
    try testing.expectError(
        Error.UnsupportedConfigProfile,
        validateConfigV1(gqa),
    );
    var too_many_layers = testConfigV1();
    too_many_layers.layers = maximum_layers_v1 + 1;
    try testing.expectError(
        Error.UnsupportedConfigProfile,
        validateConfigV1(too_many_layers),
    );
    var undersized_vocabulary = testConfigV1();
    undersized_vocabulary.vocab = minimum_vocabulary_v1 - 1;
    try testing.expectError(
        Error.UnsupportedConfigProfile,
        validateConfigV1(undersized_vocabulary),
    );
}
