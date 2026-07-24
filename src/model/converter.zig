//! Converter: HuggingFace safetensors → Glacier format (.glacier).
//!
//! Strategy (MVP):
//!   1. mmap the safetensors file read-only.
//!   2. Parse the header to enumerate tensors.
//!   3. For each tensor, classify its layer index + tensor kind from its
//!      name (heuristic — see classifyTensorName). Slice its payload into
//!      256 KiB pages of *unpacked* weight bytes.
//!   4. Apply the static precision profile to decide the *stored* precision
//!      for each page. In the MVP we do NOT actually requantize — we store
//!      the source bytes as-is and tag the page with the source dtype. The
//!      Metal dequant kernel (next milestone) will handle real INT4 storage.
//!      This is enough to validate the file format and pager end-to-end.
//!   5. Write the .glacier file: header → metadata → page index → payloads.
//!
//! NOTE on requantization: for now stored_precision == source dtype's
//! Glacier equivalent. Real quantization to INT4 lands with the Metal
//! milestone. The format, page layout, CRC and reader all work today.

const std = @import("std");
const core = @import("core");
const fmt = @import("format.zig");
const st = @import("safetensors.zig");
const runtime_image = @import("runtime_image.zig");
const crc32 = @import("../crc32.zig");

pub const ConvertError = error{
    NotImplemented,
    NotSafetensors,
    InvalidSafetensors,
    OutOfMemory,
    IoError,
    BadInputFile,
};

pub const ConvertOptions = struct {
    page_size_bytes: u64 = fmt.PAGE_SIZE_BYTES,
    /// Architecture hint, used for metadata + naming. Default "llama".
    architecture: []const u8 = "llama",
    /// Whether to verify CRCs of pages right after writing (smoke test).
    verify_on_write: bool = true,
    /// If true, quantize every supported tensor (currently F32 source) to
    /// INT4 using group_size = quant_group_size. Other dtypes are stored raw.
    quantize_int4: bool = false,
    /// Group size for INT4 quantization. 64 is a reasonable default.
    quant_group_size: u32 = 64,
    /// Optional tensor-kind overrides for quality-aware quantization. This
    /// allows sensitive projections to use different groups without paying
    /// the scale overhead across the entire model.
    quant_group_overrides: []const QuantGroupOverride = &.{},
};

pub const QuantGroupOverride = struct {
    kind: fmt.TensorKind,
    group_size: u32,
};

/// Result of a successful conversion.
pub const ConvertResult = struct {
    num_pages: u64,
    output_bytes: u64,
};

/// Layer index + tensor kind parsed from a tensor name like
/// "model.layers.5.self_attn.q_proj.weight".
pub const TensorClass = struct {
    layer_idx: u32,
    kind: fmt.TensorKind,
};

/// Best-effort name classification. Unknown names get layer 0 / .other.
pub fn classifyTensorName(name: []const u8) TensorClass {
    // Look for "layers.<n>" substring.
    var layer: u32 = 0;
    if (std.mem.indexOf(u8, name, "layers.")) |idx| {
        const rest = name[idx + "layers.".len ..];
        var end: usize = 0;
        while (end < rest.len and std.ascii.isDigit(rest[end])) : (end += 1) {}
        if (end > 0) layer = std.fmt.parseInt(u32, rest[0..end], 10) catch 0;
    }

    var kind: fmt.TensorKind = .other;
    // Check for bias tensors first — names end with ".bias" and contain the
    // projection name. Must precede the weight checks so "q_proj.bias"
    // classifies as a bias, not as attn_q.
    if (std.mem.endsWith(u8, name, ".bias") or std.mem.indexOf(u8, name, ".bias") != null) {
        if (std.mem.indexOf(u8, name, "q_proj") != null) {
            kind = .attn_q_bias;
        } else if (std.mem.indexOf(u8, name, "k_proj") != null) {
            kind = .attn_k_bias;
        } else if (std.mem.indexOf(u8, name, "v_proj") != null) {
            kind = .attn_v_bias;
        } else if (std.mem.indexOf(u8, name, "o_proj") != null) {
            kind = .attn_o_bias;
        }
    } else if (std.mem.indexOf(u8, name, "embed") != null) {
        kind = .embedding;
    } else if (std.mem.indexOf(u8, name, "q_proj") != null) {
        kind = .attn_q;
    } else if (std.mem.indexOf(u8, name, "k_proj") != null) {
        kind = .attn_k;
    } else if (std.mem.indexOf(u8, name, "v_proj") != null) {
        kind = .attn_v;
    } else if (std.mem.indexOf(u8, name, "o_proj") != null) {
        kind = .attn_o;
    } else if (std.mem.indexOf(u8, name, "gate_proj") != null) {
        kind = .mlp_gate;
    } else if (std.mem.indexOf(u8, name, "up_proj") != null) {
        kind = .mlp_up;
    } else if (std.mem.indexOf(u8, name, "down_proj") != null) {
        kind = .mlp_down;
    } else if (std.mem.indexOf(u8, name, "lm_head") != null) {
        kind = .lm_head;
    } else if (std.mem.indexOf(u8, name, "model.norm") != null) {
        kind = .final_norm;
    } else if (std.mem.indexOf(u8, name, "post_attention_layernorm") != null) {
        kind = .post_attn_norm;
    } else if (std.mem.indexOf(u8, name, "input_layernorm") != null) {
        kind = .input_norm;
    } else if (std.mem.indexOf(u8, name, "norm") != null or std.mem.indexOf(u8, name, "ln") != null) {
        kind = .input_norm;
    }

    return .{ .layer_idx = layer, .kind = kind };
}

fn dtypeToPrecision(d: st.DType) fmt.StoredPrecision {
    // The page stores raw source bytes; the tag must reflect what those
    // bytes actually are so the loader can decode them correctly.
    return switch (d) {
        .f32 => .fp32,
        .f16 => .fp16,
        .bf16 => .bf16,
        // F64 / ints: store as raw f32 (lossy but unambiguous) for MVP.
        .f64, .i64, .i32, .i16, .i8, .u8, .bool, .unknown => .fp32,
    };
}

fn srcBytesPerElem(d: st.DType) usize {
    return switch (d) {
        .f64, .i64 => 8,
        .f32, .i32 => 4,
        .f16, .bf16, .i16 => 2,
        .i8, .u8, .bool => 1,
        .unknown => 4, // fallback; will misbehave on real unknown tensors
    };
}

fn groupSizeForKind(options: ConvertOptions, kind: fmt.TensorKind) u32 {
    for (options.quant_group_overrides) |item| {
        if (item.kind == kind) return item.group_size;
    }
    return options.quant_group_size;
}

fn validQuantPageGeometry(page_size_bytes: u64, group_size: u32) bool {
    if (group_size == 0 or group_size > std.math.maxInt(u8)) return false;
    const elems_per_page = page_size_bytes / @sizeOf(f32);
    return elems_per_page >= group_size and elems_per_page % group_size == 0;
}

/// Decode raw tensor bytes (F32/F16/BF16) into an aligned []f32 buffer.
/// Used by the converter's INT4 path so it can quantize any float source.
fn decodeToAlignedF32(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    dtype: st.DType,
) ![]f32 {
    const f16bits = @import("core").f16bits;
    switch (dtype) {
        .f32 => {
            const n = bytes.len / @sizeOf(f32);
            const out = try allocator.alloc(f32, n);
            // mmap pointers may not be f32-aligned; copy byte-wise.
            const src_bytes: [*]const u8 = bytes.ptr;
            @memcpy(@as([*]u8, @ptrCast(out.ptr))[0 .. n * @sizeOf(f32)], src_bytes[0 .. n * @sizeOf(f32)]);
            return out;
        },
        .f16, .bf16 => {
            // BF16 is the top 16 bits of an FP32; f16bits.f16BitsToF32 handles
            // both since BF16 ≈ FP32 truncated. For correctness on BF16 we
            // shift the bf16 bits into the FP32 position manually.
            const n = bytes.len / 2;
            const out = try allocator.alloc(f32, n);
            for (out, 0..) |*v, i| {
                const u = std.mem.readInt(u16, bytes[i * 2 ..][0..2], .little);
                if (dtype == .bf16) {
                    // BF16: sign(1) + exp(8) + mant(7) → place into FP32 top bits.
                    const f32_bits: u32 = @as(u32, u) << 16;
                    v.* = @bitCast(f32_bits);
                } else {
                    v.* = f16bits.f16BitsToF32(u);
                }
            }
            return out;
        },
        else => return error.UnsupportedDType,
    }
}

/// Convert safetensors at `in_path` to `out_path` (.glacier).
pub fn convertSafetensors(
    allocator: std.mem.Allocator,
    in_path: []const u8,
    out_path: []const u8,
    options: ConvertOptions,
) ConvertError!ConvertResult {
    // --- Read & parse safetensors ------------------------------------------
    const in_file = std.fs.cwd().openFile(in_path, .{}) catch
        return ConvertError.BadInputFile;
    defer in_file.close();
    const stat = in_file.stat() catch return ConvertError.IoError;
    const total_size: u64 = stat.size;
    const map_len = std.math.cast(usize, total_size) orelse
        return ConvertError.BadInputFile;

    const mapping = runtime_image.ReadOnlyFileMapping.init(
        in_file,
        map_len,
    ) catch return ConvertError.IoError;
    defer mapping.close();
    const mapped = mapping.bytes;

    var sf = st.parseHeader(allocator, mapped) catch
        return ConvertError.NotSafetensors;
    defer sf.deinit();

    if (sf.tensors.len == 0) return ConvertError.NotSafetensors;

    // --- Plan pages ---------------------------------------------------------
    // For MVP each tensor's raw bytes are split at page_size_bytes boundaries.
    // row_start / row_end are page-local indices into the tensor's flat bytes.
    var plan: std.ArrayList(fmt.PageEntry) = .{};
    defer plan.deinit(allocator);
    // Owned (quantized) payloads need freeing; borrowed (mmap) slices do not.
    var owned_payloads: std.ArrayList([]u8) = .{};
    defer {
        for (owned_payloads.items) |p| allocator.free(p);
        owned_payloads.deinit(allocator);
    }
    var payloads: std.ArrayList([]const u8) = .{};
    defer payloads.deinit(allocator);

    var page_id: u64 = 0;
    for (sf.tensors) |t| {
        const cls = classifyTensorName(t.name);
        const base = sf.data_region_start + t.data_offset;
        const tensor_bytes = mapped[@intCast(base)..@intCast(base + t.byte_length)];

        // Decide whether to quantize this tensor. MVP supports F32 source → INT4.
        // Norm weights and biases are kept at full precision: they are tiny
        // (dim elements) and quantizing them hurts accuracy for no space gain.
        const is_norm_or_bias = switch (cls.kind) {
            .input_norm,
            .post_attn_norm,
            .final_norm,
            .attn_q_bias,
            .attn_k_bias,
            .attn_v_bias,
            .attn_o_bias,
            => true,
            else => false,
        };
        // Quantize any float source the engine can decode (F32, F16, BF16).
        // INT4 path decodes the source to f32 first, then quantizes.
        const is_quantizable_float = switch (t.dtype) {
            .f32, .f16, .bf16 => true,
            else => false,
        };
        const want_int4 = options.quantize_int4 and is_quantizable_float and !is_norm_or_bias;
        const group_size = groupSizeForKind(options, cls.kind);

        if (want_int4) {
            if (!validQuantPageGeometry(options.page_size_bytes, group_size)) {
                return ConvertError.BadInputFile;
            }
            // Decode source bytes (F32/F16/BF16) into an aligned f32 buffer.
            const aligned = decodeToAlignedF32(allocator, tensor_bytes, t.dtype) catch
                return ConvertError.OutOfMemory;
            defer allocator.free(aligned);
            const total_elems = aligned.len;
            const elems_per_page = options.page_size_bytes / @sizeOf(f32);

            var elem_off: usize = 0;
            while (elem_off < total_elems) {
                const n = @min(elems_per_page, total_elems - elem_off);
                const src_elems = aligned[elem_off .. elem_off + n];

                const payload = @import("qio.zig").encodePage(
                    f32,
                    allocator,
                    src_elems,
                    .int4,
                    group_size,
                ) catch return ConvertError.OutOfMemory;
                try owned_payloads.append(allocator, payload);

                try payloads.append(allocator, payload);
                try plan.append(allocator, .{
                    .page_id = page_id,
                    .layer_idx = cls.layer_idx,
                    .tensor_kind = cls.kind,
                    .row_start = elem_off,
                    .row_end = elem_off + n,
                    .precision = .int4,
                    .quant_group = @intCast(group_size),
                    .crc32 = crc32.hash(payload),
                    .data_offset = 0,
                    .data_len = payload.len,
                });
                page_id += 1;
                elem_off += n;
            }
        } else {
            // Raw storage at the source dtype. Element offsets so loader can
            // recover geometry from row_end regardless of precision.
            const prec = dtypeToPrecision(t.dtype);
            const elem_bytes: usize = srcBytesPerElem(t.dtype);
            var elem_off: usize = 0;
            const total_elems = t.byte_length / elem_bytes;
            const elems_per_page = options.page_size_bytes / elem_bytes;
            while (elem_off < total_elems) {
                const n = @min(elems_per_page, total_elems - elem_off);
                const off_bytes = elem_off * elem_bytes;
                const chunk_bytes = n * elem_bytes;
                const src = tensor_bytes[off_bytes .. off_bytes + chunk_bytes];

                try payloads.append(allocator, src);
                try plan.append(allocator, .{
                    .page_id = page_id,
                    .layer_idx = cls.layer_idx,
                    .tensor_kind = cls.kind,
                    .row_start = elem_off,
                    .row_end = elem_off + n,
                    .precision = prec,
                    .quant_group = 0,
                    .crc32 = crc32.hash(src),
                    .data_offset = 0,
                    .data_len = chunk_bytes,
                });
                page_id += 1;
                elem_off += n;
            }
        }
    }

    // --- Layout: header(256) + meta + index + payloads ---------------------
    const meta_bytes_owned = std.fmt.allocPrint(
        allocator,
        \\{{"architecture":"{s}","num_pages":{d},"page_size_bytes":{d},"created_by":"glacier-convert 0.1.0"}}
    ,
        .{ options.architecture, plan.items.len, options.page_size_bytes },
    ) catch return ConvertError.OutOfMemory;
    defer allocator.free(meta_bytes_owned);
    const meta_buf: []const u8 = meta_bytes_owned;

    const meta_offset: u64 = fmt.HEADER_SIZE;
    const meta_len: u64 = meta_buf.len;
    const index_offset: u64 = meta_offset + meta_len;
    const index_size: u64 = plan.items.len * fmt.PAGE_ENTRY_SIZE;
    var data_offset: u64 = index_offset + index_size;

    // Patch data_offset into each entry.
    for (plan.items, payloads.items) |*e, payload| {
        e.data_offset = data_offset;
        data_offset += payload.len;
    }

    const header = fmt.Header{
        .meta_offset = meta_offset,
        .meta_len = meta_len,
        .num_pages = plan.items.len,
        .page_index_offset = index_offset,
        .page_data_offset = index_offset + index_size,
    };

    // --- Write file ---------------------------------------------------------
    const out_file = std.fs.cwd().createFile(out_path, .{ .truncate = true }) catch
        return ConvertError.IoError;
    defer out_file.close();

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.Writer.initStreaming(out_file, &buf);
    defer w.interface.flush() catch {};

    header.writeTo(&w.interface) catch return ConvertError.IoError;
    w.interface.writeAll(meta_buf) catch return ConvertError.IoError;
    for (plan.items) |e| {
        e.writeTo(&w.interface) catch return ConvertError.IoError;
    }
    // Payloads: flush header+index first so we can write raw bytes next.
    w.interface.flush() catch return ConvertError.IoError;

    var total_written: u64 = fmt.HEADER_SIZE + meta_len + index_size;
    for (payloads.items) |p| {
        out_file.writeAll(p) catch return ConvertError.IoError;
        total_written += p.len;
    }

    if (options.verify_on_write) {
        try verifyOutput(allocator, out_path, plan.items.len);
    }

    return .{
        .num_pages = plan.items.len,
        .output_bytes = total_written,
    };
}

/// Open the file we just wrote and sanity-check: header magic, page count,
/// first + last page CRC.
fn verifyOutput(
    allocator: std.mem.Allocator,
    path: []const u8,
    expected_pages: usize,
) ConvertError!void {
    var reader = fmt.FileReader.open(allocator, path) catch return ConvertError.IoError;
    defer reader.close();
    if (reader.pages.len != expected_pages) return ConvertError.IoError;

    // Verify first and last page payloads.
    const first = reader.pages[0];
    const last = reader.pages[reader.pages.len - 1];
    var page_buf = try allocator.alloc(u8, @max(first.data_len, last.data_len));
    defer allocator.free(page_buf);

    reader.readPage(first, page_buf[0..@intCast(first.data_len)]) catch
        return ConvertError.IoError;
    reader.readPage(last, page_buf[0..@intCast(last.data_len)]) catch
        return ConvertError.IoError;
}

// --------------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------------

test "classify common tensor names" {
    const cases = [_]struct { name: []const u8, kind: fmt.TensorKind, layer: u32 }{
        .{ .name = "model.layers.5.self_attn.q_proj.weight", .kind = .attn_q, .layer = 5 },
        .{ .name = "model.layers.11.mlp.down_proj.weight", .kind = .mlp_down, .layer = 11 },
        .{ .name = "model.embed_tokens.weight", .kind = .embedding, .layer = 0 },
        .{ .name = "lm_head.weight", .kind = .lm_head, .layer = 0 },
        .{ .name = "model.layers.3.input_layernorm.weight", .kind = .input_norm, .layer = 3 },
        .{ .name = "model.norm.weight", .kind = .final_norm, .layer = 0 },
        .{ .name = "model.layers.7.post_attention_layernorm.weight", .kind = .post_attn_norm, .layer = 7 },
    };
    for (cases) |c| {
        const cls = classifyTensorName(c.name);
        try std.testing.expectEqual(c.kind, cls.kind);
        try std.testing.expectEqual(c.layer, cls.layer_idx);
    }
}

test "tensor-specific quantization group overrides default" {
    const overrides = [_]QuantGroupOverride{
        .{ .kind = .attn_q, .group_size = 16 },
        .{ .kind = .attn_o, .group_size = 16 },
    };
    const options: ConvertOptions = .{
        .quantize_int4 = true,
        .quant_group_size = 8,
        .quant_group_overrides = &overrides,
    };
    try std.testing.expectEqual(@as(u32, 16), groupSizeForKind(options, .attn_q));
    try std.testing.expectEqual(@as(u32, 16), groupSizeForKind(options, .attn_o));
    try std.testing.expectEqual(@as(u32, 8), groupSizeForKind(options, .mlp_down));
    try std.testing.expect(validQuantPageGeometry(fmt.PAGE_SIZE_BYTES, 8));
    try std.testing.expect(!validQuantPageGeometry(fmt.PAGE_SIZE_BYTES, 7));
}
