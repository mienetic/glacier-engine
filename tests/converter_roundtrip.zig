//! End-to-end test: build a tiny safetensors file on disk, convert it
//! to Glacier format, then open the result and verify page layout, CRCs,
//! and tensor classification.

const std = @import("std");
const engine = @import("engine");

const testing = std.testing;

fn pathInTmp(tmp: *testing.TmpDir, basename: []const u8) ![]u8 {
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);
    return std.fs.path.join(testing.allocator, &.{ root, basename });
}

/// Build a minimal safetensors file on disk with two tensors that exercise
/// the name classifier: one attention tensor on layer 5 and one MLP tensor
/// on layer 11. Small payloads so we get one page each.
fn writeSampleSafetensors(path: []const u8) !void {
    const json =
        \\{"model.layers.5.self_attn.q_proj.weight":{"dtype":"F32","shape":[4,4],"data_offsets":[0,16]},
        \\"model.layers.11.mlp.down_proj.weight":{"dtype":"F32","shape":[8,4],"data_offsets":[16,144]},
        \\"__metadata__":{"format":"pt"}}
    ;
    const header_len: u64 = @intCast(json.len);
    const data_len: u64 = 144;
    const total: u64 = 8 + header_len + data_len;

    const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();

    var hdr_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &hdr_buf, header_len, .little);
    try f.writeAll(&hdr_buf);
    try f.writeAll(json);
    // Data region: fill with a recognizable pattern.
    var i: u8 = 0;
    var data = [_]u8{0} ** 144;
    for (&data) |*b| {
        b.* = i;
        i +%= 7;
    }
    try f.writeAll(&data);
    _ = total;
}

test "convert safetensors → glacier round-trip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const in_path = try pathInTmp(&tmp, "input.safetensors");
    defer testing.allocator.free(in_path);
    const out_path = try pathInTmp(&tmp, "output.glacier");
    defer testing.allocator.free(out_path);

    try writeSampleSafetensors(in_path);

    const result = try engine.converter.convertSafetensors(
        testing.allocator,
        in_path,
        out_path,
        .{ .verify_on_write = true, .page_size_bytes = 64 }, // small pages → multi-page
    );
    // 16 + 128 = 144 bytes total, page size 64 → 16/64=1 page + 128/64=2 pages = 3 pages.
    try testing.expectEqual(@as(u64, 3), result.num_pages);

    // Read back and inspect.
    var reader = try engine.model.FileReader.open(testing.allocator, out_path);
    defer reader.close();

    try testing.expectEqual(@as(usize, 3), reader.pages.len);

    // First page should be the q_proj on layer 5.
    try testing.expectEqual(@as(u32, 5), reader.pages[0].layer_idx);
    try testing.expectEqual(engine.model.TensorKind.attn_q, reader.pages[0].tensor_kind);

    // Pages 1 and 2 are the down_proj on layer 11.
    try testing.expectEqual(@as(u32, 11), reader.pages[1].layer_idx);
    try testing.expectEqual(engine.model.TensorKind.mlp_down, reader.pages[1].tensor_kind);
    try testing.expectEqual(@as(u32, 11), reader.pages[2].layer_idx);
    try testing.expectEqual(engine.model.TensorKind.mlp_down, reader.pages[2].tensor_kind);

    // Verify all three page payloads via CRC (readPage asserts CRC internally).
    var page_buf: [128]u8 = undefined;
    for (reader.pages) |p| {
        try reader.readPage(p, &page_buf);
    }
}

test "bulk page-index read rejects a truncated index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const in_path = try pathInTmp(&tmp, "input.safetensors");
    defer testing.allocator.free(in_path);
    const out_path = try pathInTmp(&tmp, "output.glacier");
    defer testing.allocator.free(out_path);

    try writeSampleSafetensors(in_path);
    _ = try engine.converter.convertSafetensors(
        testing.allocator,
        in_path,
        out_path,
        .{ .page_size_bytes = 64 },
    );

    const truncate_at = blk: {
        var reader = try engine.model.FileReader.open(testing.allocator, out_path);
        defer reader.close();
        try testing.expect(reader.pages.len > 1);
        break :blk reader.header.page_index_offset + engine.model.PAGE_ENTRY_SIZE;
    };
    {
        const file = try std.fs.cwd().openFile(out_path, .{ .mode = .read_write });
        defer file.close();
        try file.setEndPos(truncate_at);
    }

    try testing.expectError(
        error.TruncatedIndex,
        engine.model.FileReader.open(testing.allocator, out_path),
    );
}

test "convert rejects non-safetensors input" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_path = try pathInTmp(&tmp, "bad.bin");
    defer testing.allocator.free(bad_path);
    const out_path = try pathInTmp(&tmp, "output.glacier");
    defer testing.allocator.free(out_path);

    const f = try std.fs.cwd().createFile(bad_path, .{ .truncate = true });
    defer f.close();
    try f.writeAll("not a safetensors file at all");

    const err = engine.converter.convertSafetensors(
        testing.allocator,
        bad_path,
        out_path,
        .{},
    );
    try testing.expectError(engine.converter.ConvertError.NotSafetensors, err);
}

/// Build a safetensors file whose payload is a real F32 tensor with
/// realistic-weight-like values, so INT4 quantization is meaningful.
fn writeSampleF32Safetensors(path: []const u8, values: []const f32) !void {
    const json_prefix =
        \\{"weights":{"dtype":"F32","shape":[
    ;
    const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();

    // Build header JSON with the right shape/length.
    var hdr_buf: [256]u8 = undefined;
    const data_len = values.len * @sizeOf(f32);
    const json = std.fmt.bufPrint(&hdr_buf,
        \\{{"weights":{{"dtype":"F32","shape":[{d}],"data_offsets":[0,{d}]}}}}
    , .{ values.len, data_len }) catch unreachable;

    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, @intCast(json.len), .little);
    try f.writeAll(&len_buf);
    try f.writeAll(json);

    _ = json_prefix;
    var bytes: [@sizeOf(f32)]u8 = undefined;
    for (values) |v| {
        std.mem.writeInt(u32, &bytes, @bitCast(v), .little);
        try f.writeAll(&bytes);
    }
}

test "INT4 quantization round-trips through .glacier file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const in_path = try pathInTmp(&tmp, "input.safetensors");
    defer testing.allocator.free(in_path);
    const out_path = try pathInTmp(&tmp, "output.glacier");
    defer testing.allocator.free(out_path);

    // 256 f32 values in [-0.5, 0.5] — realistic for a small weight row.
    var rng = std.Random.DefaultPrng.init(123);
    var src: [256]f32 = undefined;
    for (&src) |*v| v.* = (rng.random().float(f32) * 2 - 1) * 0.5;
    try writeSampleF32Safetensors(in_path, &src);

    const result = try engine.converter.convertSafetensors(
        testing.allocator,
        in_path,
        out_path,
        .{
            .quantize_int4 = true,
            .quant_group_size = 64,
            .page_size_bytes = 256, // 256 bytes = 64 f32 elements per page
        },
    );
    // 256 elements / 64 per page = 4 pages.
    try testing.expectEqual(@as(u64, 4), result.num_pages);

    // Read all pages back and dequantize, concatenating.
    var reader = try engine.model.FileReader.open(testing.allocator, out_path);
    defer reader.close();
    try testing.expectEqual(@as(usize, 4), reader.pages.len);
    for (reader.pages) |p| try testing.expectEqual(engine.model.StoredPrecision.int4, p.precision);

    var all_back: [256]f32 = undefined;
    var dst_off: usize = 0;
    var total_payload_bytes: u64 = 0;
    for (reader.pages) |p| {
        const back = try reader.readPageDequant(f32, p);
        defer testing.allocator.free(back);
        @memcpy(all_back[dst_off .. dst_off + back.len], back);
        dst_off += back.len;
        total_payload_bytes += p.data_len;
    }
    try testing.expectEqual(src.len, dst_off);

    // INT4 over ±0.5 with group_size 64 → step ≈ 0.5/7 ≈ 0.071, half-step ≈ 0.036.
    var max_abs: f32 = 0;
    for (src, all_back[0..src.len]) |a, b| {
        const err: f32 = if (a > b) a - b else b - a;
        if (err > max_abs) max_abs = err;
    }
    try testing.expect(max_abs < 0.06);

    // And the total on-disk payload must be smaller than the raw F32 bytes.
    try testing.expect(total_payload_bytes < src.len * @sizeOf(f32));
}

test "non-quantized conversion keeps raw bytes intact" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const in_path = try pathInTmp(&tmp, "input.safetensors");
    defer testing.allocator.free(in_path);
    const out_path = try pathInTmp(&tmp, "output.glacier");
    defer testing.allocator.free(out_path);

    var src: [16]f32 = undefined;
    for (&src, 0..) |*v, i| v.* = @floatFromInt(i);
    try writeSampleF32Safetensors(in_path, &src);

    _ = try engine.converter.convertSafetensors(
        testing.allocator,
        in_path,
        out_path,
        .{ .quantize_int4 = false },
    );

    var reader = try engine.model.FileReader.open(testing.allocator, out_path);
    defer reader.close();
    try testing.expectEqual(engine.model.StoredPrecision.fp32, reader.pages[0].precision);

    const back = try reader.readPageDequant(f32, reader.pages[0]);
    defer testing.allocator.free(back);
    // Raw mode returns the source bytes reinterpreted; integer values survive.
    try testing.expectEqual(src.len, back.len);
    for (src, back) |a, b| try testing.expectEqual(a, b);
}
