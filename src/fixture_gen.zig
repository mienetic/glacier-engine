//! Parametric synthetic-model generator.
//!
//! Writes a small-but-realistic Llama-style safetensors file with the
//! requested geometry. Used by `glacier gen-fixture` to produce bench
//! inputs without downloading a HF model. The fixture generator in
//! tests/model_forward.zig is a fixed-geometry copy of this; keep them
//! in sync if you change tensor names here.

const std = @import("std");

pub const Geometry = struct {
    dim: usize = 128,
    hidden_dim: usize = 256,
    num_layers: usize = 4,
    vocab_size: usize = 256,
};

pub fn writeSafetensors(path: []const u8, geom: Geometry) !void {
    const allocator = std.heap.page_allocator;
    var rng = std.Random.DefaultPrng.init(2024);

    const TensorEntry = struct {
        name: []const u8,
        dims: [4]usize,
        n_dims: u8,
        offset: u64,
        len: u64,
    };

    var tensors: std.ArrayList(TensorEntry) = .{};
    defer {
        for (tensors.items) |t| {
            if (std.mem.startsWith(u8, t.name, "model.layers.")) allocator.free(t.name);
        }
        tensors.deinit(allocator);
    }

    var offset: u64 = 0;

    // Embedding: [vocab, dim].
    {
        const n = geom.vocab_size * geom.dim;
        try tensors.append(allocator, .{
            .name = "model.embed_tokens.weight",
            .dims = .{ geom.vocab_size, geom.dim, 0, 0 },
            .n_dims = 2,
            .offset = offset,
            .len = @intCast(n * 4),
        });
        offset += n * 4;
    }

    const LayerSpec = struct { suffix: []const u8, dims: [4]usize, n_dims: u8 };
    const layer_specs = [_]LayerSpec{
        .{ .suffix = "input_layernorm.weight", .dims = .{ geom.dim, 0, 0, 0 }, .n_dims = 1 },
        .{ .suffix = "self_attn.q_proj.weight", .dims = .{ geom.dim, geom.dim, 0, 0 }, .n_dims = 2 },
        .{ .suffix = "self_attn.k_proj.weight", .dims = .{ geom.dim, geom.dim, 0, 0 }, .n_dims = 2 },
        .{ .suffix = "self_attn.v_proj.weight", .dims = .{ geom.dim, geom.dim, 0, 0 }, .n_dims = 2 },
        .{ .suffix = "self_attn.o_proj.weight", .dims = .{ geom.dim, geom.dim, 0, 0 }, .n_dims = 2 },
        .{ .suffix = "post_attention_layernorm.weight", .dims = .{ geom.dim, 0, 0, 0 }, .n_dims = 1 },
        .{ .suffix = "mlp.gate_proj.weight", .dims = .{ geom.hidden_dim, geom.dim, 0, 0 }, .n_dims = 2 },
        .{ .suffix = "mlp.up_proj.weight", .dims = .{ geom.hidden_dim, geom.dim, 0, 0 }, .n_dims = 2 },
        .{ .suffix = "mlp.down_proj.weight", .dims = .{ geom.dim, geom.hidden_dim, 0, 0 }, .n_dims = 2 },
    };
    var layer: usize = 0;
    while (layer < geom.num_layers) : (layer += 1) {
        for (layer_specs) |spec| {
            var n: usize = 1;
            for (spec.dims[0..spec.n_dims]) |d| n *= d;
            const name = try std.fmt.allocPrint(allocator, "model.layers.{d}.{s}", .{ layer, spec.suffix });
            try tensors.append(allocator, .{
                .name = name,
                .dims = spec.dims,
                .n_dims = spec.n_dims,
                .offset = offset,
                .len = @intCast(n * 4),
            });
            offset += n * 4;
        }
    }

    // Final norm + lm_head.
    {
        try tensors.append(allocator, .{
            .name = "model.norm.weight",
            .dims = .{ geom.dim, 0, 0, 0 },
            .n_dims = 1,
            .offset = offset,
            .len = @intCast(geom.dim * 4),
        });
        offset += geom.dim * 4;
    }
    {
        const n = geom.vocab_size * geom.dim;
        try tensors.append(allocator, .{
            .name = "lm_head.weight",
            .dims = .{ geom.vocab_size, geom.dim, 0, 0 },
            .n_dims = 2,
            .offset = offset,
            .len = @intCast(n * 4),
        });
        offset += n * 4;
    }

    // Build JSON header.
    var json_buf: [65536]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&json_buf);
    const jw = fbs.writer();
    try jw.writeAll("{");
    var first = true;
    for (tensors.items) |t| {
        if (!first) try jw.writeAll(",");
        first = false;
        try jw.writeAll("\"");
        try jw.writeAll(t.name);
        try jw.writeAll("\":{\"dtype\":\"F32\",\"shape\":[");
        for (t.dims[0..t.n_dims], 0..) |d, i| {
            if (i > 0) try jw.writeAll(",");
            try jw.print("{d}", .{d});
        }
        try jw.writeAll("],\"data_offsets\":[");
        try jw.print("{d},{d}", .{ t.offset, t.offset + t.len });
        try jw.writeAll("]}");
    }
    try jw.writeAll(",\"__metadata__\":{\"format\":\"pt\"}}");
    const json_slice = json_buf[0..fbs.pos];

    const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();

    var hdr_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &hdr_buf, @intCast(json_slice.len), .little);
    try f.writeAll(&hdr_buf);
    try f.writeAll(json_slice);

    // Write data.
    for (tensors.items) |t| {
        var n: usize = 1;
        for (t.dims[0..t.n_dims]) |d| n *= d;
        const scale: f32 = if (std.mem.indexOf(u8, t.name, "embed") != null or
            std.mem.indexOf(u8, t.name, "lm_head") != null)
            0.02
        else if (std.mem.indexOf(u8, t.name, "layernorm") != null)
            0.05
        else
            0.04;
        var bytes: [4]u8 = undefined;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const v: f32 = rng.random().floatNorm(f32) * scale;
            std.mem.writeInt(u32, &bytes, @bitCast(v), .little);
            try f.writeAll(&bytes);
        }
    }
}
