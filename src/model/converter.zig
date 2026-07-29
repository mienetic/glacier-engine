//! Converter: HuggingFace safetensors → Glacier format (.glacier).
//!
//! The converter plans deterministic pages up to the V1 256 KiB quantum,
//! reserves the complete container layout, then transforms and writes one page
//! at a time through a bounded reusable workspace. Caller-owned file APIs make
//! publication policy explicit: conversion itself never closes, synchronizes,
//! renames, or changes either borrowed descriptor's stream position.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const fmt = @import("format.zig");
const qio = @import("qio.zig");
const st = @import("safetensors.zig");
const crc32 = @import("../crc32.zig");

pub const Digest = [32]u8;
pub const conversion_profile_abi: u64 = 0x474c_4350_0000_0001;
pub const conversion_plan_abi: u64 = 0x474c_434e_0000_0001;

const conversion_profile_domain =
    "glacier-model-conversion-profile-v1\x00";
const conversion_plan_domain =
    "glacier-model-conversion-plan-v1\x00";
const metadata_schema = "glacier.model-conversion/v1";
const metadata_created_by = "glacier-convert 0.2.0";
const verification_chunk_bytes: usize = 64 * 1024;
const atomic_candidate_prefix = ".glacier-convert-";

pub const ConvertError = error{
    NotImplemented,
    NotSafetensors,
    InvalidSafetensors,
    UnsupportedSourceDType,
    InvalidOptions,
    ResourceLimit,
    OutOfMemory,
    IoError,
    BadInputFile,
    OutputNotEmpty,
    SourceOutputAlias,
    SourceChanged,
    OutputVerificationFailed,
};

pub const ConvertOptions = struct {
    page_size_bytes: u64 = fmt.PAGE_SIZE_BYTES,
    /// Architecture hint used for metadata and identity.
    architecture: []const u8 = "generic-transformer",
    /// Deprecated runtime-only compatibility flag. V1 conversion always
    /// verifies the complete candidate before success, and this value does not
    /// affect either conversion identity root.
    verify_on_write: bool = true,
    /// If true, quantize eligible F32/F16/BF16 tensors to INT4 using
    /// group_size = quant_group_size. Norm and bias tensors remain lossless.
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
    source_bytes: u64,
    source_sha256: Digest,
    conversion_profile_sha256: Digest,
    conversion_plan_sha256: Digest,
    output_sha256: Digest,
    /// Peak size of the one reusable heap buffer used for source reads,
    /// per-page transformation, and candidate verification. Descriptor,
    /// header/JSON, and page-plan allocations are excluded from this bound and
    /// are not reported separately.
    conversion_workspace_bytes_peak: u64,
};

pub const ConversionProgressPhaseV1 = enum(u8) {
    layout_reserved,
    payload_page_completed,
};

pub const ConversionProgressV1 = struct {
    phase: ConversionProgressPhaseV1,
    completed_pages: u64,
    total_pages: u64,
};

/// Optional protocol-neutral progress observation. The callback grants no file
/// or publication authority and is deliberately excluded from both conversion
/// identity roots.
pub const ConversionProgressObserverV1 = struct {
    context: *anyopaque,
    observe_fn: *const fn (
        context: *anyopaque,
        progress: ConversionProgressV1,
    ) anyerror!void,

    fn observe(
        self: ConversionProgressObserverV1,
        progress: ConversionProgressV1,
    ) !void {
        try self.observe_fn(self.context, progress);
    }
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
    return switch (d) {
        .f32 => .fp32,
        .f16 => .fp16,
        .bf16 => .bf16,
        else => unreachable,
    };
}

fn srcBytesPerElem(d: st.DType) usize {
    return switch (d) {
        .f32 => 4,
        .f16, .bf16 => 2,
        else => 0,
    };
}

fn groupSizeForKind(options: ConvertOptions, kind: fmt.TensorKind) u32 {
    for (options.quant_group_overrides) |item| {
        if (item.kind == kind) return item.group_size;
    }
    return options.quant_group_size;
}

fn kindUsesInt4V1(kind: fmt.TensorKind) bool {
    return switch (kind) {
        .input_norm,
        .post_attn_norm,
        .final_norm,
        .attn_q_bias,
        .attn_k_bias,
        .attn_v_bias,
        .attn_o_bias,
        => false,
        else => true,
    };
}

fn validQuantPageGeometry(page_size_bytes: u64, group_size: u32) bool {
    if (group_size == 0 or group_size > std.math.maxInt(u8)) return false;
    const elems_per_page = page_size_bytes / @sizeOf(f32);
    return elems_per_page >= group_size and elems_per_page % group_size == 0;
}

fn readSourcePageF32V1(
    file: std.fs.File,
    source_offset: u64,
    dtype: st.DType,
    destination: []f32,
    scratch: []u8,
) ConvertError!void {
    const element_bytes = srcBytesPerElem(dtype);
    if (element_bytes == 0 or scratch.len < element_bytes)
        return ConvertError.OutOfMemory;
    const elements_per_chunk = scratch.len / element_bytes;
    const f16bits = core.f16bits;
    var completed: usize = 0;
    while (completed < destination.len) {
        const chunk_elements = @min(
            destination.len - completed,
            elements_per_chunk,
        );
        const chunk_bytes = chunk_elements * element_bytes;
        const encoded = scratch[0..chunk_bytes];
        const read_offset = checkedAddU64(
            source_offset,
            checkedMulU64(
                completed,
                element_bytes,
            ) catch return ConvertError.SourceChanged,
        ) catch return ConvertError.SourceChanged;
        const read = file.preadAll(
            encoded,
            read_offset,
        ) catch return ConvertError.SourceChanged;
        if (read != encoded.len)
            return ConvertError.SourceChanged;
        for (destination[completed .. completed + chunk_elements], 0..) |
            *value,
            index,
        | {
            const at = index * element_bytes;
            value.* = switch (dtype) {
                .f32 => @bitCast(std.mem.readInt(
                    u32,
                    encoded[at..][0..@sizeOf(u32)],
                    .little,
                )),
                .f16 => f16bits.f16BitsToF32(std.mem.readInt(
                    u16,
                    encoded[at..][0..@sizeOf(u16)],
                    .little,
                )),
                .bf16 => @bitCast(
                    @as(u32, std.mem.readInt(
                        u16,
                        encoded[at..][0..@sizeOf(u16)],
                        .little,
                    )) << 16,
                ),
                else => return ConvertError.UnsupportedSourceDType,
            };
        }
        completed += chunk_elements;
    }
}

const FileHeaderParseErrorV1 =
    st.ParseError || error{SourceReadFailed};

fn parseSafetensorsFileV1(
    allocator: std.mem.Allocator,
    file: std.fs.File,
    file_size: u64,
) FileHeaderParseErrorV1!st.SafetensorsFile {
    if (file_size < @sizeOf(u64))
        return st.ParseError.BadHeaderLength;
    var length_bytes: [@sizeOf(u64)]u8 = undefined;
    const length_read = file.preadAll(
        &length_bytes,
        0,
    ) catch return error.SourceReadFailed;
    if (length_read != length_bytes.len)
        return st.ParseError.BadHeaderLength;
    const header_len = std.mem.readInt(
        u64,
        &length_bytes,
        .little,
    );
    if (header_len > st.MAX_HEADER_BYTES)
        return st.ParseError.HeaderTooLarge;
    const prefix_len_u64 = std.math.add(
        u64,
        length_bytes.len,
        header_len,
    ) catch return st.ParseError.BadHeaderLength;
    if (prefix_len_u64 > file_size)
        return st.ParseError.BadHeaderLength;
    const prefix_len = std.math.cast(
        usize,
        prefix_len_u64,
    ) orelse return st.ParseError.BadHeaderLength;
    const prefix = try allocator.alloc(u8, prefix_len);
    defer allocator.free(prefix);
    const prefix_read = file.preadAll(
        prefix,
        0,
    ) catch return error.SourceReadFailed;
    if (prefix_read != prefix.len)
        return error.SourceReadFailed;
    return st.parseHeaderPrefix(
        allocator,
        prefix,
        file_size,
    );
}

const PagePlanV1 = struct {
    entry: fmt.PageEntry,
    source_offset: u64,
    source_bytes: usize,
    source_dtype: st.DType,
    quantized: bool,
};

const known_tensor_kinds = [_]fmt.TensorKind{
    .embedding,
    .attn_q,
    .attn_k,
    .attn_v,
    .attn_o,
    .mlp_up,
    .mlp_down,
    .mlp_gate,
    .input_norm,
    .lm_head,
    .final_norm,
    .post_attn_norm,
    .attn_q_bias,
    .attn_k_bias,
    .attn_v_bias,
    .attn_o_bias,
    .other,
};

/// Convert safetensors at `in_path` to `out_path` (`.glacier`).
///
/// This compatibility path owns its descriptors and publishes through a
/// same-directory private candidate. Any conversion or pre-publication failure
/// leaves an existing target untouched. It provides file-atomic replacement,
/// not directory durability; durable publishers should call the borrowed-file
/// API through their own synchronized publication protocol.
pub fn convertSafetensors(
    allocator: std.mem.Allocator,
    in_path: []const u8,
    out_path: []const u8,
    options: ConvertOptions,
) ConvertError!ConvertResult {
    try validateOptionsV1(options);
    const input_file = std.fs.cwd().openFile(in_path, .{}) catch
        return ConvertError.BadInputFile;
    defer input_file.close();

    const target_name = std.fs.path.basename(out_path);
    if (target_name.len == 0)
        return ConvertError.IoError;
    var output_dir = std.fs.cwd();
    var close_output_dir = false;
    if (std.fs.path.dirname(out_path)) |parent_path| {
        output_dir = if (std.fs.path.isAbsolute(parent_path))
            std.fs.openDirAbsolute(parent_path, .{}) catch
                return ConvertError.IoError
        else
            std.fs.cwd().openDir(parent_path, .{}) catch
                return ConvertError.IoError;
        close_output_dir = true;
    }
    defer if (close_output_dir) output_dir.close();

    try rejectExistingTargetAliasV1(
        input_file,
        output_dir,
        target_name,
    );

    var candidate_name_buffer: [64]u8 = undefined;
    var candidate_name: []const u8 = undefined;
    var candidate_file: std.fs.File = undefined;
    while (true) {
        candidate_name = std.fmt.bufPrint(
            &candidate_name_buffer,
            "{s}{x}",
            .{
                atomic_candidate_prefix,
                std.crypto.random.int(u64),
            },
        ) catch return ConvertError.IoError;
        if (std.mem.eql(u8, candidate_name, target_name))
            continue;
        candidate_file = output_dir.createFile(candidate_name, .{
            .read = true,
            .exclusive = true,
            .mode = 0o600,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return ConvertError.IoError,
        };
        break;
    }
    var candidate_open = true;
    defer if (candidate_open) candidate_file.close();
    var candidate_exists = true;
    defer if (candidate_exists)
        output_dir.deleteFile(candidate_name) catch {};

    const result = try convertSafetensorsFilesV1(
        allocator,
        input_file,
        candidate_file,
        options,
    );
    // Recheck after conversion so a target that became a source alias while
    // the candidate was being built cannot be replaced.
    try rejectExistingTargetAliasV1(
        input_file,
        output_dir,
        target_name,
    );

    candidate_file.close();
    candidate_open = false;
    output_dir.rename(
        candidate_name,
        target_name,
    ) catch return ConvertError.IoError;
    candidate_exists = false;
    return result;
}

/// Convert from one borrowed input descriptor into one borrowed empty output
/// descriptor. The output descriptor must be readable and writable. The caller
/// retains both descriptors. This function never closes, synchronizes, renames,
/// or changes either descriptor's stream position.
pub fn convertSafetensorsFilesV1(
    allocator: std.mem.Allocator,
    input_file: std.fs.File,
    empty_output_file: std.fs.File,
    options: ConvertOptions,
) ConvertError!ConvertResult {
    return convertSafetensorsFilesImpl(
        false,
        allocator,
        input_file,
        empty_output_file,
        options,
        {},
    );
}

/// Fallible progress-observing variant used by publication and recovery
/// protocols. Observer identity and failures do not enter either conversion
/// root. A callback runs once after the complete layout is reserved and once
/// after every payload and its final index entry have been written.
pub fn convertSafetensorsFilesWithObserverV1(
    allocator: std.mem.Allocator,
    input_file: std.fs.File,
    empty_output_file: std.fs.File,
    options: ConvertOptions,
    observer: ?ConversionProgressObserverV1,
) anyerror!ConvertResult {
    return convertSafetensorsFilesImpl(
        true,
        allocator,
        input_file,
        empty_output_file,
        options,
        observer,
    );
}

fn convertSafetensorsFilesImpl(
    comptime has_observer: bool,
    allocator: std.mem.Allocator,
    input_file: std.fs.File,
    empty_output_file: std.fs.File,
    options: ConvertOptions,
    observer: if (has_observer) ?ConversionProgressObserverV1 else void,
) (if (has_observer) anyerror else ConvertError)!ConvertResult {
    try validateOptionsV1(options);

    const source_stat_before = input_file.stat() catch
        return ConvertError.BadInputFile;
    const output_stat_before = empty_output_file.stat() catch
        return ConvertError.IoError;
    if (source_stat_before.kind != .file)
        return ConvertError.BadInputFile;
    if (output_stat_before.kind != .file)
        return ConvertError.IoError;
    if (try sameFileV1(input_file, empty_output_file))
        return ConvertError.SourceOutputAlias;
    if (output_stat_before.size != 0)
        return ConvertError.OutputNotEmpty;
    if (source_stat_before.size == 0)
        return ConvertError.NotSafetensors;

    var safetensors = parseSafetensorsFileV1(
        allocator,
        input_file,
        source_stat_before.size,
    ) catch |err|
        switch (err) {
            error.OutOfMemory => return ConvertError.OutOfMemory,
            error.UnsupportedDType => {
                return ConvertError.UnsupportedSourceDType;
            },
            error.HeaderTooLarge => return ConvertError.ResourceLimit,
            error.SourceReadFailed => return ConvertError.BadInputFile,
            error.BadHeaderLength,
            error.NotSafetensors,
            => return ConvertError.NotSafetensors,
            error.InvalidTensor,
            error.NonContiguousData,
            error.JsonError,
            => return ConvertError.InvalidSafetensors,
        };
    defer safetensors.deinit();
    if (safetensors.tensors.len == 0)
        return ConvertError.NotSafetensors;

    var pages: std.ArrayList(PagePlanV1) = .{};
    defer pages.deinit(allocator);
    var maximum_quant_workspace: usize = 0;
    var maximum_payload_bytes: usize = 0;
    try planPagesV1(
        allocator,
        source_stat_before.size,
        safetensors,
        options,
        &pages,
        &maximum_quant_workspace,
        &maximum_payload_bytes,
    );
    if (pages.items.len == 0)
        return ConvertError.NotSafetensors;
    if (pages.items.len > fmt.MAX_PAGE_COUNT_V1)
        return ConvertError.ResourceLimit;

    const verification_workspace = @min(
        maximum_payload_bytes,
        verification_chunk_bytes,
    );
    const source_read_workspace: usize = @intCast(@min(
        source_stat_before.size,
        @as(u64, verification_chunk_bytes),
    ));
    const workspace_bytes = @max(
        maximum_quant_workspace,
        @max(
            verification_workspace,
            source_read_workspace,
        ),
    );
    const workspace = allocator.alignedAlloc(
        u8,
        .@"4",
        @max(workspace_bytes, 1),
    ) catch return ConvertError.OutOfMemory;
    defer allocator.free(workspace);
    const stream_workspace = streamWorkspaceV1(workspace);

    const source_sha256 = hashFileV1(
        input_file,
        source_stat_before.size,
        stream_workspace,
        ConvertError.BadInputFile,
    ) catch return ConvertError.BadInputFile;
    const source_stat_after_capture = input_file.stat() catch
        return ConvertError.SourceChanged;
    if (sourceChangedV1(
        source_stat_before,
        source_stat_after_capture,
    ))
        return ConvertError.SourceChanged;
    const conversion_profile_sha256 =
        try conversionProfileSha256V1(options);

    const zero_digest: Digest = [_]u8{0} ** @sizeOf(Digest);
    const placeholder_metadata = try metadataBytesV1(
        allocator,
        options,
        @intCast(pages.items.len),
        source_stat_before.size,
        source_sha256,
        conversion_profile_sha256,
        zero_digest,
    );
    const metadata_bytes = placeholder_metadata.len;
    allocator.free(placeholder_metadata);

    const metadata_offset: u64 = fmt.HEADER_SIZE;
    const metadata_end = checkedAddU64(
        metadata_offset,
        metadata_bytes,
    ) catch return ConvertError.BadInputFile;
    const index_bytes = checkedMulU64(
        pages.items.len,
        fmt.PAGE_ENTRY_SIZE,
    ) catch return ConvertError.BadInputFile;
    const payload_offset = checkedAddU64(
        metadata_end,
        index_bytes,
    ) catch return ConvertError.BadInputFile;
    var output_bytes = payload_offset;
    for (pages.items) |*page| {
        page.entry.data_offset = output_bytes;
        output_bytes = checkedAddU64(
            output_bytes,
            page.entry.data_len,
        ) catch return ConvertError.BadInputFile;
    }

    const conversion_plan_sha256 = conversionPlanSha256V1(
        source_stat_before.size,
        source_sha256,
        conversion_profile_sha256,
        metadata_bytes,
        payload_offset,
        output_bytes,
        pages.items,
    );
    const metadata = try metadataBytesV1(
        allocator,
        options,
        @intCast(pages.items.len),
        source_stat_before.size,
        source_sha256,
        conversion_profile_sha256,
        conversion_plan_sha256,
    );
    defer allocator.free(metadata);
    if (metadata.len != metadata_bytes)
        return ConvertError.OutputVerificationFailed;

    const header = fmt.Header{
        .meta_offset = metadata_offset,
        .meta_len = @intCast(metadata.len),
        .num_pages = @intCast(pages.items.len),
        .page_index_offset = metadata_end,
        .page_data_offset = payload_offset,
        // The V1 header advertises the fixed maximum page quantum. The
        // conversion profile and metadata bind the selected (possibly
        // smaller) deterministic chunk size.
        .page_size_log2 = fmt.PAGE_SIZE_LOG2,
    };
    const encoded_header = try encodeHeaderV1(header);

    empty_output_file.pwriteAll(
        &encoded_header,
        0,
    ) catch return ConvertError.IoError;
    empty_output_file.pwriteAll(
        metadata,
        metadata_offset,
    ) catch return ConvertError.IoError;
    for (pages.items, 0..) |page, index| {
        const encoded_entry = try encodePageEntryV1(page.entry);
        const entry_offset = checkedAddU64(
            metadata_end,
            checkedMulU64(
                index,
                fmt.PAGE_ENTRY_SIZE,
            ) catch return ConvertError.BadInputFile,
        ) catch return ConvertError.BadInputFile;
        empty_output_file.pwriteAll(
            &encoded_entry,
            entry_offset,
        ) catch return ConvertError.IoError;
    }
    empty_output_file.setEndPos(output_bytes) catch
        return ConvertError.IoError;

    if (comptime has_observer) {
        if (observer) |value| try value.observe(.{
            .phase = .layout_reserved,
            .completed_pages = 0,
            .total_pages = @intCast(pages.items.len),
        });
    }

    for (pages.items, 0..) |*page, index| {
        const source_end = checkedAddU64(
            page.source_offset,
            page.source_bytes,
        ) catch return ConvertError.BadInputFile;
        if (source_end > source_stat_before.size)
            return ConvertError.BadInputFile;
        if (page.quantized) {
            var fixed = std.heap.FixedBufferAllocator.init(workspace);
            const page_allocator = fixed.allocator();
            const element_bytes = srcBytesPerElem(page.source_dtype);
            if (element_bytes == 0 or
                page.source_bytes % element_bytes != 0)
                return ConvertError.InvalidSafetensors;
            const aligned = page_allocator.alloc(
                f32,
                page.source_bytes / element_bytes,
            ) catch return ConvertError.OutOfMemory;
            const decoded_end = std.math.sub(
                usize,
                @intFromPtr(aligned.ptr) +
                    aligned.len * @sizeOf(f32),
                @intFromPtr(workspace.ptr),
            ) catch return ConvertError.OutOfMemory;
            if (decoded_end >= workspace.len)
                return ConvertError.OutOfMemory;
            try readSourcePageF32V1(
                input_file,
                page.source_offset,
                page.source_dtype,
                aligned,
                streamWorkspaceV1(workspace[decoded_end..]),
            );
            const encoded = qio.encodePage(
                f32,
                page_allocator,
                aligned,
                .int4,
                @as(u32, page.entry.quant_group),
            ) catch return ConvertError.OutOfMemory;
            if (encoded.len != page.entry.data_len)
                return ConvertError.OutputVerificationFailed;
            page.entry.crc32 = crc32.hash(encoded);
            empty_output_file.pwriteAll(
                encoded,
                page.entry.data_offset,
            ) catch return ConvertError.IoError;
        } else {
            page.entry.crc32 = try copyRawSourcePageV1(
                input_file,
                empty_output_file,
                page.source_offset,
                page.entry.data_offset,
                page.source_bytes,
                stream_workspace,
            );
        }
        const encoded_entry = try encodePageEntryV1(page.entry);
        const entry_offset = checkedAddU64(
            metadata_end,
            checkedMulU64(
                index,
                fmt.PAGE_ENTRY_SIZE,
            ) catch return ConvertError.BadInputFile,
        ) catch return ConvertError.BadInputFile;
        empty_output_file.pwriteAll(
            &encoded_entry,
            entry_offset,
        ) catch return ConvertError.IoError;

        if (comptime has_observer) {
            if (observer) |value| try value.observe(.{
                .phase = .payload_page_completed,
                .completed_pages = @intCast(index + 1),
                .total_pages = @intCast(pages.items.len),
            });
        }
    }

    const source_stat_after_write = input_file.stat() catch
        return ConvertError.SourceChanged;
    if (sourceChangedV1(
        source_stat_before,
        source_stat_after_write,
    ))
        return ConvertError.SourceChanged;

    const output_sha256 = try verifyOutputFileV1(
        empty_output_file,
        &encoded_header,
        metadata,
        metadata_end,
        pages.items,
        output_bytes,
        stream_workspace,
    );

    // Re-read the descriptor after every output byte has been written and
    // verified so ordinary in-place edits cannot publish under the captured
    // source identity.
    const source_sha256_after = hashFileV1(
        input_file,
        source_stat_before.size,
        stream_workspace,
        ConvertError.SourceChanged,
    ) catch return ConvertError.SourceChanged;
    const source_stat_after_hash = input_file.stat() catch
        return ConvertError.SourceChanged;
    if (sourceChangedV1(
        source_stat_before,
        source_stat_after_hash,
    ) or !digestEqual(source_sha256, source_sha256_after))
        return ConvertError.SourceChanged;

    return .{
        .num_pages = @intCast(pages.items.len),
        .output_bytes = output_bytes,
        .source_bytes = source_stat_before.size,
        .source_sha256 = source_sha256,
        .conversion_profile_sha256 = conversion_profile_sha256,
        .conversion_plan_sha256 = conversion_plan_sha256,
        .output_sha256 = output_sha256,
        .conversion_workspace_bytes_peak = @intCast(workspace.len),
    };
}

fn validateOptionsV1(options: ConvertOptions) ConvertError!void {
    if (options.architecture.len == 0 or
        options.architecture.len > 1024 or
        !std.unicode.utf8ValidateSlice(options.architecture) or
        options.page_size_bytes < @sizeOf(f32) or
        options.page_size_bytes > fmt.PAGE_SIZE_BYTES or
        !std.math.isPowerOfTwo(options.page_size_bytes))
        return ConvertError.InvalidOptions;
    if (!options.quantize_int4)
        return;

    for (options.quant_group_overrides, 0..) |item, index| {
        if (!kindUsesInt4V1(item.kind))
            continue;
        for (options.quant_group_overrides[0..index]) |previous| {
            if (kindUsesInt4V1(previous.kind) and
                previous.kind == item.kind)
                return ConvertError.InvalidOptions;
        }
    }
    for (known_tensor_kinds) |kind| {
        if (!kindUsesInt4V1(kind))
            continue;
        const group_size = groupSizeForKind(options, kind);
        if (group_size == 0 or
            group_size > std.math.maxInt(u8))
            return ConvertError.InvalidOptions;
    }
}

/// Canonical identity for output-affecting conversion behavior. Runtime-only
/// verification and progress options are intentionally excluded.
pub fn conversionProfileSha256V1(
    options: ConvertOptions,
) ConvertError!Digest {
    try validateOptionsV1(options);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(conversion_profile_domain);
    hashU64(&hash, conversion_profile_abi);
    hashU64(&hash, fmt.VERSION);
    hashU64(&hash, fmt.HEADER_SIZE);
    hashU64(&hash, fmt.PAGE_ENTRY_SIZE);
    hashU64(&hash, qio.PAYLOAD_MAGIC);
    hashU64(&hash, qio.SUB_HEADER_SIZE);
    hashU64(&hash, options.page_size_bytes);
    hashBytes(&hash, options.architecture);
    hashU8(&hash, @intFromBool(options.quantize_int4));
    var effective_kind_count: u64 = 0;
    if (options.quantize_int4) {
        for (known_tensor_kinds) |kind| {
            effective_kind_count += @intFromBool(
                kindUsesInt4V1(kind),
            );
        }
    }
    hashU64(&hash, effective_kind_count);
    if (options.quantize_int4) {
        for (known_tensor_kinds) |kind| {
            if (!kindUsesInt4V1(kind))
                continue;
            hashU32(&hash, @intFromEnum(kind));
            hashU32(&hash, groupSizeForKind(options, kind));
        }
    }
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn planPagesV1(
    allocator: std.mem.Allocator,
    source_file_bytes: u64,
    safetensors: st.SafetensorsFile,
    options: ConvertOptions,
    pages: *std.ArrayList(PagePlanV1),
    maximum_quant_workspace: *usize,
    maximum_payload_bytes: *usize,
) ConvertError!void {
    const page_size = std.math.cast(
        usize,
        options.page_size_bytes,
    ) orelse return ConvertError.InvalidOptions;
    var page_id: u64 = 0;

    for (safetensors.tensors) |tensor| {
        switch (tensor.dtype) {
            .f32, .f16, .bf16 => {},
            else => return ConvertError.UnsupportedSourceDType,
        }
        const classification = classifyTensorName(tensor.name);
        const element_bytes = srcBytesPerElem(tensor.dtype);
        if (element_bytes == 0 or
            tensor.byte_length % element_bytes != 0)
            return ConvertError.InvalidSafetensors;
        const tensor_base_u64 = checkedAddU64(
            safetensors.data_region_start,
            tensor.data_offset,
        ) catch return ConvertError.InvalidSafetensors;
        const tensor_end_u64 = checkedAddU64(
            tensor_base_u64,
            tensor.byte_length,
        ) catch return ConvertError.InvalidSafetensors;
        if (tensor_end_u64 > source_file_bytes)
            return ConvertError.InvalidSafetensors;
        const total_elements = std.math.cast(
            usize,
            tensor.byte_length / element_bytes,
        ) orelse return ConvertError.InvalidSafetensors;

        const is_quantizable_float = switch (tensor.dtype) {
            .f32, .f16, .bf16 => true,
            else => false,
        };
        const quantized = options.quantize_int4 and
            is_quantizable_float and
            kindUsesInt4V1(classification.kind);
        const group_size = groupSizeForKind(
            options,
            classification.kind,
        );
        const elements_per_page = if (quantized)
            page_size / @sizeOf(f32)
        else
            page_size / element_bytes;
        if (elements_per_page == 0)
            return ConvertError.InvalidOptions;
        if (quantized and
            !validQuantPageGeometry(
                options.page_size_bytes,
                group_size,
            ))
            return ConvertError.InvalidOptions;
        _ = try preflightPageCountV1(
            page_id,
            total_elements,
            elements_per_page,
        );

        var element_offset: usize = 0;
        while (element_offset < total_elements) {
            const element_count = @min(
                elements_per_page,
                total_elements - element_offset,
            );
            const source_byte_offset = std.math.mul(
                usize,
                element_offset,
                element_bytes,
            ) catch return ConvertError.InvalidSafetensors;
            const source_bytes = std.math.mul(
                usize,
                element_count,
                element_bytes,
            ) catch return ConvertError.InvalidSafetensors;
            const source_offset = checkedAddU64(
                tensor_base_u64,
                source_byte_offset,
            ) catch return ConvertError.InvalidSafetensors;
            const payload_bytes = if (quantized)
                quantizedPayloadBytesV1(
                    element_count,
                    group_size,
                ) catch return ConvertError.InvalidOptions
            else
                source_bytes;

            if (quantized) {
                maximum_quant_workspace.* = @max(
                    maximum_quant_workspace.*,
                    quantizationWorkspaceBytesV1(
                        element_count,
                        group_size,
                    ) catch return ConvertError.InvalidOptions,
                );
            }
            maximum_payload_bytes.* = @max(
                maximum_payload_bytes.*,
                payload_bytes,
            );
            if (page_id >= fmt.MAX_PAGE_COUNT_V1)
                return ConvertError.ResourceLimit;
            pages.append(allocator, .{
                .entry = .{
                    .page_id = page_id,
                    .layer_idx = classification.layer_idx,
                    .tensor_kind = classification.kind,
                    .row_start = @intCast(element_offset),
                    .row_end = @intCast(
                        element_offset + element_count,
                    ),
                    .precision = if (quantized)
                        .int4
                    else
                        dtypeToPrecision(tensor.dtype),
                    .quant_group = if (quantized)
                        @intCast(group_size)
                    else
                        0,
                    .crc32 = 0,
                    .data_offset = 0,
                    .data_len = @intCast(payload_bytes),
                },
                .source_offset = source_offset,
                .source_bytes = source_bytes,
                .source_dtype = tensor.dtype,
                .quantized = quantized,
            }) catch return ConvertError.OutOfMemory;
            page_id = std.math.add(
                u64,
                page_id,
                1,
            ) catch return ConvertError.InvalidSafetensors;
            element_offset += element_count;
        }
    }
}

fn preflightPageCountV1(
    current_page_count: u64,
    total_elements: usize,
    elements_per_page: usize,
) ConvertError!u64 {
    if (elements_per_page == 0)
        return ConvertError.InvalidOptions;
    const tensor_page_count = std.math.cast(
        u64,
        ceilDiv(total_elements, elements_per_page),
    ) orelse return ConvertError.ResourceLimit;
    const final_page_count = std.math.add(
        u64,
        current_page_count,
        tensor_page_count,
    ) catch return ConvertError.ResourceLimit;
    if (final_page_count > fmt.MAX_PAGE_COUNT_V1)
        return ConvertError.ResourceLimit;
    return final_page_count;
}

fn quantizedPayloadBytesV1(
    elements: usize,
    group_size: u32,
) error{Overflow}!usize {
    const groups = ceilDiv(elements, group_size);
    const scales_bytes = std.math.mul(
        usize,
        groups,
        @sizeOf(f32),
    ) catch return error.Overflow;
    const packed_bytes = ceilDiv(elements, 2);
    const body_bytes = std.math.add(
        usize,
        scales_bytes,
        packed_bytes,
    ) catch return error.Overflow;
    return std.math.add(
        usize,
        qio.SUB_HEADER_SIZE,
        body_bytes,
    ) catch return error.Overflow;
}

fn quantizationWorkspaceBytesV1(
    elements: usize,
    group_size: u32,
) error{Overflow}!usize {
    const decoded_bytes = std.math.mul(
        usize,
        elements,
        @sizeOf(f32),
    ) catch return error.Overflow;
    const groups = ceilDiv(elements, group_size);
    const scales_bytes = std.math.mul(
        usize,
        groups,
        @sizeOf(f32),
    ) catch return error.Overflow;
    const packed_bytes = ceilDiv(elements, 2);
    const payload_bytes = try quantizedPayloadBytesV1(
        elements,
        group_size,
    );
    var total = std.math.add(
        usize,
        decoded_bytes,
        scales_bytes,
    ) catch return error.Overflow;
    total = std.math.add(
        usize,
        total,
        packed_bytes,
    ) catch return error.Overflow;
    return std.math.add(
        usize,
        total,
        payload_bytes,
    ) catch return error.Overflow;
}

fn metadataBytesV1(
    allocator: std.mem.Allocator,
    options: ConvertOptions,
    page_count: u64,
    source_bytes: u64,
    source_sha256: Digest,
    conversion_profile_sha256: Digest,
    conversion_plan_sha256: Digest,
) ConvertError![]u8 {
    const source_hex = std.fmt.bytesToHex(
        source_sha256,
        .lower,
    );
    const profile_hex = std.fmt.bytesToHex(
        conversion_profile_sha256,
        .lower,
    );
    const plan_hex = std.fmt.bytesToHex(
        conversion_plan_sha256,
        .lower,
    );
    return std.json.Stringify.valueAlloc(
        allocator,
        .{
            .schema = metadata_schema,
            .architecture = options.architecture,
            .num_pages = page_count,
            .page_size_bytes = options.page_size_bytes,
            .source_bytes = source_bytes,
            .source_sha256 = source_hex[0..],
            .conversion_profile_sha256 = profile_hex[0..],
            .conversion_plan_sha256 = plan_hex[0..],
            .created_by = metadata_created_by,
        },
        .{},
    ) catch return ConvertError.OutOfMemory;
}

fn conversionPlanSha256V1(
    source_bytes: u64,
    source_sha256: Digest,
    conversion_profile_sha256: Digest,
    metadata_bytes: usize,
    payload_offset: u64,
    output_bytes: u64,
    pages: []const PagePlanV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(conversion_plan_domain);
    hashU64(&hash, conversion_plan_abi);
    hashBytes(&hash, metadata_schema);
    hashBytes(&hash, metadata_created_by);
    hashU64(&hash, source_bytes);
    hash.update(&source_sha256);
    hash.update(&conversion_profile_sha256);
    hashU64(&hash, metadata_bytes);
    hashU64(&hash, payload_offset);
    hashU64(&hash, output_bytes);
    hashU64(&hash, pages.len);
    for (pages) |page| {
        const entry = page.entry;
        hashU64(&hash, entry.page_id);
        hashU32(&hash, entry.layer_idx);
        hashU32(&hash, @intFromEnum(entry.tensor_kind));
        hashU64(&hash, entry.row_start);
        hashU64(&hash, entry.row_end);
        hashU8(&hash, @intFromEnum(entry.precision));
        hashU8(&hash, entry.quant_group);
        hashU64(&hash, entry.data_offset);
        hashU64(&hash, entry.data_len);
        hashU64(&hash, page.source_offset);
        hashU64(&hash, page.source_bytes);
        hashU8(&hash, @intFromEnum(page.source_dtype));
        hashU8(&hash, @intFromBool(page.quantized));
    }
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn encodeHeaderV1(
    header: fmt.Header,
) ConvertError![fmt.HEADER_SIZE]u8 {
    var encoded: [fmt.HEADER_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&encoded);
    header.writeTo(stream.writer()) catch
        return ConvertError.OutputVerificationFailed;
    if (stream.getWritten().len != encoded.len)
        return ConvertError.OutputVerificationFailed;
    return encoded;
}

fn encodePageEntryV1(
    entry: fmt.PageEntry,
) ConvertError![fmt.PAGE_ENTRY_SIZE]u8 {
    var encoded: [fmt.PAGE_ENTRY_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&encoded);
    entry.writeTo(stream.writer()) catch
        return ConvertError.OutputVerificationFailed;
    if (stream.getWritten().len != encoded.len)
        return ConvertError.OutputVerificationFailed;
    return encoded;
}

fn verifyOutputFileV1(
    output_file: std.fs.File,
    expected_header: *const [fmt.HEADER_SIZE]u8,
    metadata: []const u8,
    index_offset: u64,
    pages: []const PagePlanV1,
    output_bytes: u64,
    workspace: []u8,
) ConvertError!Digest {
    const output_stat = output_file.stat() catch
        return ConvertError.OutputVerificationFailed;
    if (output_stat.kind != .file or
        output_stat.size != output_bytes or
        workspace.len == 0)
        return ConvertError.OutputVerificationFailed;

    var actual_header: [fmt.HEADER_SIZE]u8 = undefined;
    try preadExactV1(output_file, &actual_header, 0);
    if (!std.mem.eql(
        u8,
        expected_header[0..],
        actual_header[0..],
    ))
        return ConvertError.OutputVerificationFailed;
    try compareFileRangeV1(
        output_file,
        fmt.HEADER_SIZE,
        metadata,
        workspace,
    );

    for (pages, 0..) |page, index| {
        const expected_entry = try encodePageEntryV1(
            page.entry,
        );
        var actual_entry: [fmt.PAGE_ENTRY_SIZE]u8 = undefined;
        const entry_offset = checkedAddU64(
            index_offset,
            checkedMulU64(
                index,
                fmt.PAGE_ENTRY_SIZE,
            ) catch return ConvertError.OutputVerificationFailed,
        ) catch return ConvertError.OutputVerificationFailed;
        try preadExactV1(
            output_file,
            &actual_entry,
            entry_offset,
        );
        if (!std.mem.eql(
            u8,
            &expected_entry,
            &actual_entry,
        ))
            return ConvertError.OutputVerificationFailed;

        var page_crc = crc32.Hasher.init();
        var cursor = page.entry.data_offset;
        var remaining = page.entry.data_len;
        while (remaining != 0) {
            const chunk_u64 = @min(
                remaining,
                @as(u64, @intCast(workspace.len)),
            );
            const chunk: usize = @intCast(chunk_u64);
            try preadExactV1(
                output_file,
                workspace[0..chunk],
                cursor,
            );
            page_crc.update(workspace[0..chunk]);
            cursor = checkedAddU64(
                cursor,
                chunk,
            ) catch return ConvertError.OutputVerificationFailed;
            remaining -= chunk;
        }
        if (page_crc.final() != page.entry.crc32)
            return ConvertError.OutputVerificationFailed;
    }
    return try hashFileV1(
        output_file,
        output_bytes,
        workspace,
        ConvertError.OutputVerificationFailed,
    );
}

fn streamWorkspaceV1(workspace: []u8) []u8 {
    std.debug.assert(workspace.len != 0);
    return workspace[0..@min(
        workspace.len,
        verification_chunk_bytes,
    )];
}

fn copyRawSourcePageV1(
    input_file: std.fs.File,
    output_file: std.fs.File,
    source_offset: u64,
    output_offset: u64,
    byte_count: usize,
    workspace: []u8,
) ConvertError!u32 {
    if (workspace.len == 0)
        return ConvertError.OutOfMemory;
    var hash = crc32.Hasher.init();
    var copied: usize = 0;
    while (copied < byte_count) {
        const chunk_len = @min(
            byte_count - copied,
            workspace.len,
        );
        const chunk = workspace[0..chunk_len];
        const source_at = checkedAddU64(
            source_offset,
            copied,
        ) catch return ConvertError.SourceChanged;
        const read = input_file.preadAll(
            chunk,
            source_at,
        ) catch return ConvertError.SourceChanged;
        if (read != chunk.len)
            return ConvertError.SourceChanged;
        const output_at = checkedAddU64(
            output_offset,
            copied,
        ) catch return ConvertError.IoError;
        output_file.pwriteAll(
            chunk,
            output_at,
        ) catch return ConvertError.IoError;
        hash.update(chunk);
        copied += chunk.len;
    }
    return hash.final();
}

fn compareFileRangeV1(
    file: std.fs.File,
    start_offset: u64,
    expected: []const u8,
    workspace: []u8,
) ConvertError!void {
    var compared: usize = 0;
    while (compared < expected.len) {
        const chunk = @min(
            workspace.len,
            expected.len - compared,
        );
        const offset = checkedAddU64(
            start_offset,
            compared,
        ) catch return ConvertError.OutputVerificationFailed;
        try preadExactV1(
            file,
            workspace[0..chunk],
            offset,
        );
        if (!std.mem.eql(
            u8,
            workspace[0..chunk],
            expected[compared .. compared + chunk],
        ))
            return ConvertError.OutputVerificationFailed;
        compared += chunk;
    }
}

fn hashFileV1(
    file: std.fs.File,
    byte_count: u64,
    workspace: []u8,
    failure: ConvertError,
) ConvertError!Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var cursor: u64 = 0;
    while (cursor < byte_count) {
        const chunk_u64 = @min(
            byte_count - cursor,
            @as(u64, @intCast(workspace.len)),
        );
        const chunk: usize = @intCast(chunk_u64);
        const bytes_read = file.preadAll(
            workspace[0..chunk],
            cursor,
        ) catch return failure;
        if (bytes_read != chunk)
            return failure;
        hash.update(workspace[0..chunk]);
        cursor = checkedAddU64(
            cursor,
            chunk,
        ) catch return failure;
    }
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn preadExactV1(
    file: std.fs.File,
    destination: []u8,
    offset: u64,
) ConvertError!void {
    const bytes_read = file.preadAll(
        destination,
        offset,
    ) catch return ConvertError.OutputVerificationFailed;
    if (bytes_read != destination.len)
        return ConvertError.OutputVerificationFailed;
}

const FileIdentityV1 = struct {
    volume: u64,
    file: u64,
};

fn fileIdentityV1(
    file: std.fs.File,
) ConvertError!FileIdentityV1 {
    if (comptime builtin.os.tag == .windows) {
        const windows = std.os.windows;
        var io_status: windows.IO_STATUS_BLOCK = undefined;
        var volume_info: windows.FILE_FS_VOLUME_INFORMATION = undefined;
        switch (windows.ntdll.NtQueryVolumeInformationFile(
            file.handle,
            &io_status,
            &volume_info,
            @sizeOf(windows.FILE_FS_VOLUME_INFORMATION),
            .FileFsVolumeInformation,
        )) {
            .SUCCESS, .BUFFER_OVERFLOW => {},
            else => return ConvertError.IoError,
        }
        var internal_info: windows.FILE_INTERNAL_INFORMATION = undefined;
        switch (windows.ntdll.NtQueryInformationFile(
            file.handle,
            &io_status,
            &internal_info,
            @sizeOf(windows.FILE_INTERNAL_INFORMATION),
            .FileInternalInformation,
        )) {
            .SUCCESS => {},
            else => return ConvertError.IoError,
        }
        return .{
            .volume = volume_info.VolumeSerialNumber,
            .file = @bitCast(internal_info.IndexNumber),
        };
    }
    const raw = std.posix.fstat(file.handle) catch
        return ConvertError.IoError;
    return .{
        .volume = std.math.cast(u64, raw.dev) orelse
            return ConvertError.IoError,
        .file = std.math.cast(u64, raw.ino) orelse
            return ConvertError.IoError,
    };
}

fn sameFileV1(
    left_file: std.fs.File,
    right_file: std.fs.File,
) ConvertError!bool {
    if (left_file.handle == right_file.handle)
        return true;
    return std.meta.eql(
        try fileIdentityV1(left_file),
        try fileIdentityV1(right_file),
    );
}

fn rejectExistingTargetAliasV1(
    source_file: std.fs.File,
    directory: std.fs.Dir,
    target_name: []const u8,
) ConvertError!void {
    const target_file = directory.openFile(
        target_name,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return ConvertError.IoError,
    };
    defer target_file.close();
    if (try sameFileV1(source_file, target_file))
        return ConvertError.SourceOutputAlias;
}

fn sourceChangedV1(
    before: std.fs.File.Stat,
    after: std.fs.File.Stat,
) bool {
    return before.inode != after.inode or
        before.size != after.size or
        before.mtime != after.mtime or
        before.ctime != after.ctime;
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, left[0..], right[0..]);
}

fn checkedAddU64(
    left_value: anytype,
    right_value: anytype,
) error{Overflow}!u64 {
    const left = std.math.cast(
        u64,
        left_value,
    ) orelse return error.Overflow;
    const right = std.math.cast(
        u64,
        right_value,
    ) orelse return error.Overflow;
    return std.math.add(
        u64,
        left,
        right,
    ) catch return error.Overflow;
}

fn checkedMulU64(
    left_value: anytype,
    right_value: anytype,
) error{Overflow}!u64 {
    const left = std.math.cast(
        u64,
        left_value,
    ) orelse return error.Overflow;
    const right = std.math.cast(
        u64,
        right_value,
    ) orelse return error.Overflow;
    return std.math.mul(
        u64,
        left,
        right,
    ) catch return error.Overflow;
}

fn hashBytes(
    hash: *std.crypto.hash.sha2.Sha256,
    bytes: []const u8,
) void {
    hashU64(hash, bytes.len);
    hash.update(bytes);
}

fn hashU8(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u8,
) void {
    hash.update(&.{value});
}

fn hashU32(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u32,
) void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, value, .little);
    hash.update(&encoded);
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: anytype,
) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(
        u64,
        &encoded,
        @intCast(value),
        .little,
    );
    hash.update(&encoded);
}

inline fn ceilDiv(
    numerator: usize,
    denominator_value: anytype,
) usize {
    const denominator: usize = @intCast(
        denominator_value,
    );
    return numerator / denominator +
        @intFromBool(numerator % denominator != 0);
}

// --------------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------------

fn writeTestSafetensorsV1(
    file: std.fs.File,
    dtype: []const u8,
    element_count: usize,
    payload: []const u8,
) !u64 {
    var json_buffer: [512]u8 = undefined;
    const json = try std.fmt.bufPrint(
        &json_buffer,
        "{{\"model.layers.0.self_attn.q_proj.weight\":" ++
            "{{\"dtype\":\"{s}\",\"shape\":[{d}]," ++
            "\"data_offsets\":[0,{d}]}}}}",
        .{ dtype, element_count, payload.len },
    );
    var header_length: [8]u8 = undefined;
    std.mem.writeInt(
        u64,
        &header_length,
        @intCast(json.len),
        .little,
    );
    try file.setEndPos(0);
    try file.pwriteAll(&header_length, 0);
    try file.pwriteAll(json, header_length.len);
    try file.pwriteAll(payload, header_length.len + json.len);
    return header_length.len + json.len;
}

fn testF32PayloadV1(comptime count: usize) [count * @sizeOf(f32)]u8 {
    var result: [count * @sizeOf(f32)]u8 = undefined;
    for (0..count) |index| {
        const value: f32 = @as(f32, @floatFromInt(index)) / 32.0 - 2.0;
        std.mem.writeInt(
            u32,
            result[index * @sizeOf(f32) ..][0..@sizeOf(f32)],
            @bitCast(value),
            .little,
        );
    }
    return result;
}

const ProgressCaptureV1 = struct {
    events: [4]ConversionProgressV1 = undefined,
    count: usize = 0,
    fail_on_event: ?usize = null,

    fn observe(
        context: *anyopaque,
        progress: ConversionProgressV1,
    ) anyerror!void {
        const self: *ProgressCaptureV1 = @ptrCast(@alignCast(context));
        if (self.count >= self.events.len)
            return error.TooManyProgressEvents;
        self.events[self.count] = progress;
        self.count += 1;
        if (self.fail_on_event == self.count)
            return error.ProgressStopped;
    }
};

const SourceMutationObserverV1 = struct {
    file: std.fs.File,
    byte_offset: u64,
    changed: bool = false,

    fn observe(
        context: *anyopaque,
        progress: ConversionProgressV1,
    ) anyerror!void {
        const self: *SourceMutationObserverV1 =
            @ptrCast(@alignCast(context));
        if (progress.phase != .layout_reserved or self.changed)
            return;
        var byte: [1]u8 = undefined;
        if (try self.file.preadAll(&byte, self.byte_offset) != byte.len)
            return error.TruncatedTestSource;
        byte[0] ^= 1;
        try self.file.pwriteAll(&byte, self.byte_offset);
        self.changed = true;
    }
};

const SourceTruncateObserverV1 = struct {
    file: std.fs.File,
    new_size: u64,
    changed: bool = false,

    fn observe(
        context: *anyopaque,
        progress: ConversionProgressV1,
    ) anyerror!void {
        const self: *SourceTruncateObserverV1 =
            @ptrCast(@alignCast(context));
        if (progress.phase != .layout_reserved or self.changed)
            return;
        try self.file.setEndPos(self.new_size);
        self.changed = true;
    }
};

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

test "conversion profile hashes only effective quantization behavior" {
    const ignored = [_]QuantGroupOverride{
        .{ .kind = .input_norm, .group_size = 0 },
        .{ .kind = .attn_q, .group_size = 17 },
        .{ .kind = .attn_q, .group_size = 19 },
    };
    const raw_default = try conversionProfileSha256V1(.{});
    const raw_irrelevant = try conversionProfileSha256V1(.{
        .verify_on_write = false,
        .quant_group_size = 0,
        .quant_group_overrides = &ignored,
    });
    try std.testing.expectEqualSlices(
        u8,
        &raw_default,
        &raw_irrelevant,
    );

    const ordered = [_]QuantGroupOverride{
        .{ .kind = .attn_q, .group_size = 16 },
        .{ .kind = .input_norm, .group_size = 0 },
        .{ .kind = .attn_o, .group_size = 32 },
    };
    const reordered = [_]QuantGroupOverride{
        .{ .kind = .attn_o, .group_size = 32 },
        .{ .kind = .final_norm, .group_size = 255 },
        .{ .kind = .attn_q, .group_size = 16 },
    };
    const first = try conversionProfileSha256V1(.{
        .quantize_int4 = true,
        .quant_group_overrides = &ordered,
    });
    const second = try conversionProfileSha256V1(.{
        .quantize_int4 = true,
        .verify_on_write = false,
        .quant_group_overrides = &reordered,
    });
    try std.testing.expectEqualSlices(u8, &first, &second);

    const changed = [_]QuantGroupOverride{
        .{ .kind = .attn_q, .group_size = 32 },
        .{ .kind = .attn_o, .group_size = 32 },
    };
    const changed_digest = try conversionProfileSha256V1(.{
        .quantize_int4 = true,
        .quant_group_overrides = &changed,
    });
    try std.testing.expect(!digestEqual(first, changed_digest));
}

test "page-count limit is rejected before page-plan allocation" {
    const excessive_elements = fmt.MAX_PAGE_COUNT_V1 + 1;
    const excessive_bytes = std.math.mul(
        u64,
        excessive_elements,
        @sizeOf(f32),
    ) catch unreachable;
    var header_json: [0]u8 = .{};
    var tensors = [_]st.TensorInfo{.{
        .name = "weights",
        .dtype = .f32,
        .byte_length = excessive_bytes,
        .data_offset = 0,
        .shape = &.{excessive_elements},
    }};
    var safetensors: st.SafetensorsFile = .{
        .allocator = std.testing.allocator,
        .arena = std.heap.ArenaAllocator.init(
            std.testing.allocator,
        ),
        .header_json = &header_json,
        .tensors = &tensors,
        .data_region_start = 0,
    };
    defer safetensors.deinit();
    var pages: std.ArrayList(PagePlanV1) = .{};
    defer pages.deinit(std.testing.allocator);
    var maximum_quant_workspace: usize = 0;
    var maximum_payload_bytes: usize = 0;
    try std.testing.expectError(
        ConvertError.ResourceLimit,
        planPagesV1(
            std.testing.allocator,
            excessive_bytes,
            safetensors,
            .{ .page_size_bytes = @sizeOf(f32) },
            &pages,
            &maximum_quant_workspace,
            &maximum_payload_bytes,
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        pages.items.len,
    );
}

test "streaming file IO never uses more than 64 KiB of quant workspace" {
    const large_workspace = try std.testing.allocator.alloc(
        u8,
        verification_chunk_bytes + 1,
    );
    defer std.testing.allocator.free(large_workspace);
    try std.testing.expectEqual(
        @as(usize, verification_chunk_bytes),
        streamWorkspaceV1(large_workspace).len,
    );

    var small_workspace: [17]u8 = undefined;
    try std.testing.expectEqual(
        small_workspace.len,
        streamWorkspaceV1(&small_workspace).len,
    );
}

test "borrowed conversion is deterministic and preserves caller file positions" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const input = try temporary.dir.createFile(
        "source.safetensors",
        .{ .read = true },
    );
    defer input.close();
    const payload = testF32PayloadV1(128);
    _ = try writeTestSafetensorsV1(input, "F32", 128, &payload);
    try input.seekTo(3);
    const input_position = try input.getPos();

    const first_output = try temporary.dir.createFile(
        "first.glacier",
        .{ .read = true },
    );
    defer first_output.close();
    const first_output_position = try first_output.getPos();
    const options: ConvertOptions = .{ .quantize_int4 = true };
    const first = try convertSafetensorsFilesV1(
        std.testing.allocator,
        input,
        first_output,
        options,
    );

    try std.testing.expectEqual(input_position, try input.getPos());
    try std.testing.expectEqual(
        first_output_position,
        try first_output.getPos(),
    );
    try std.testing.expectEqual(@as(u64, 1), first.num_pages);
    try std.testing.expectEqual(
        @as(u64, 672),
        first.conversion_workspace_bytes_peak,
    );
    try std.testing.expectEqual(
        first.output_bytes,
        (try first_output.stat()).size,
    );

    const second_output = try temporary.dir.createFile(
        "second.glacier",
        .{ .read = true },
    );
    defer second_output.close();
    const second = try convertSafetensorsFilesV1(
        std.testing.allocator,
        input,
        second_output,
        options,
    );
    try std.testing.expectEqual(first.output_bytes, second.output_bytes);
    try std.testing.expectEqualSlices(
        u8,
        &first.source_sha256,
        &second.source_sha256,
    );
    try std.testing.expectEqualSlices(
        u8,
        &first.conversion_profile_sha256,
        &second.conversion_profile_sha256,
    );
    try std.testing.expectEqualSlices(
        u8,
        &first.conversion_plan_sha256,
        &second.conversion_plan_sha256,
    );
    try std.testing.expectEqualSlices(
        u8,
        &first.output_sha256,
        &second.output_sha256,
    );
}

test "borrowed conversion rejects nonempty output and unsupported source dtype" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const float_input = try temporary.dir.createFile(
        "float.safetensors",
        .{ .read = true },
    );
    defer float_input.close();
    const float_payload = testF32PayloadV1(4);
    _ = try writeTestSafetensorsV1(
        float_input,
        "F32",
        4,
        &float_payload,
    );
    const nonempty_output = try temporary.dir.createFile(
        "nonempty.glacier",
        .{ .read = true },
    );
    defer nonempty_output.close();
    try nonempty_output.writeAll("keep");
    try std.testing.expectError(
        ConvertError.OutputNotEmpty,
        convertSafetensorsFilesV1(
            std.testing.allocator,
            float_input,
            nonempty_output,
            .{},
        ),
    );
    var unchanged: [4]u8 = undefined;
    try std.testing.expectEqual(
        unchanged.len,
        try nonempty_output.preadAll(&unchanged, 0),
    );
    try std.testing.expectEqualSlices(u8, "keep", &unchanged);

    const integer_input = try temporary.dir.createFile(
        "integer.safetensors",
        .{ .read = true },
    );
    defer integer_input.close();
    const integer_payload = [_]u8{0} ** 16;
    _ = try writeTestSafetensorsV1(
        integer_input,
        "I32",
        4,
        &integer_payload,
    );
    const empty_output = try temporary.dir.createFile(
        "unsupported.glacier",
        .{ .read = true },
    );
    defer empty_output.close();
    try std.testing.expectError(
        ConvertError.UnsupportedSourceDType,
        convertSafetensorsFilesV1(
            std.testing.allocator,
            integer_input,
            empty_output,
            .{},
        ),
    );
    try std.testing.expectError(
        ConvertError.InvalidOptions,
        conversionProfileSha256V1(.{
            .page_size_bytes = fmt.PAGE_SIZE_BYTES * 2,
        }),
    );
}

test "progress observer reports reservation and completed pages and may fail" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const input = try temporary.dir.createFile(
        "source.safetensors",
        .{ .read = true },
    );
    defer input.close();
    const payload = testF32PayloadV1(128);
    _ = try writeTestSafetensorsV1(input, "F32", 128, &payload);

    const output = try temporary.dir.createFile(
        "observed.glacier",
        .{ .read = true },
    );
    defer output.close();
    var capture: ProgressCaptureV1 = .{};
    _ = try convertSafetensorsFilesWithObserverV1(
        std.testing.allocator,
        input,
        output,
        .{ .quantize_int4 = true },
        .{
            .context = &capture,
            .observe_fn = ProgressCaptureV1.observe,
        },
    );
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqual(
        ConversionProgressPhaseV1.layout_reserved,
        capture.events[0].phase,
    );
    try std.testing.expectEqual(@as(u64, 0), capture.events[0].completed_pages);
    try std.testing.expectEqual(@as(u64, 1), capture.events[0].total_pages);
    try std.testing.expectEqual(
        ConversionProgressPhaseV1.payload_page_completed,
        capture.events[1].phase,
    );
    try std.testing.expectEqual(@as(u64, 1), capture.events[1].completed_pages);
    try std.testing.expectEqual(@as(u64, 1), capture.events[1].total_pages);

    const stopped_output = try temporary.dir.createFile(
        "stopped.glacier",
        .{ .read = true },
    );
    defer stopped_output.close();
    var stopped: ProgressCaptureV1 = .{ .fail_on_event = 1 };
    try std.testing.expectError(
        error.ProgressStopped,
        convertSafetensorsFilesWithObserverV1(
            std.testing.allocator,
            input,
            stopped_output,
            .{ .quantize_int4 = true },
            .{
                .context = &stopped,
                .observe_fn = ProgressCaptureV1.observe,
            },
        ),
    );
}

test "borrowed conversion rejects a source changed after planning" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const input = try temporary.dir.createFile(
        "mutable.safetensors",
        .{ .read = true },
    );
    defer input.close();
    const payload = testF32PayloadV1(4);
    const payload_offset = try writeTestSafetensorsV1(
        input,
        "F32",
        4,
        &payload,
    );
    const output = try temporary.dir.createFile(
        "changed.glacier",
        .{ .read = true },
    );
    defer output.close();
    var mutation: SourceMutationObserverV1 = .{
        .file = input,
        .byte_offset = payload_offset,
    };
    try std.testing.expectError(
        ConvertError.SourceChanged,
        convertSafetensorsFilesWithObserverV1(
            std.testing.allocator,
            input,
            output,
            .{},
            .{
                .context = &mutation,
                .observe_fn = SourceMutationObserverV1.observe,
            },
        ),
    );
    try std.testing.expect(mutation.changed);
}

test "positional source reads return SourceChanged after truncation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const input = try temporary.dir.createFile(
        "truncated.safetensors",
        .{ .read = true },
    );
    defer input.close();
    const payload = testF32PayloadV1(128);
    const payload_offset = try writeTestSafetensorsV1(
        input,
        "F32",
        128,
        &payload,
    );
    const output = try temporary.dir.createFile(
        "truncated.glacier",
        .{ .read = true },
    );
    defer output.close();
    var truncation: SourceTruncateObserverV1 = .{
        .file = input,
        .new_size = payload_offset,
    };
    try std.testing.expectError(
        ConvertError.SourceChanged,
        convertSafetensorsFilesWithObserverV1(
            std.testing.allocator,
            input,
            output,
            .{},
            .{
                .context = &truncation,
                .observe_fn = SourceTruncateObserverV1.observe,
            },
        ),
    );
    try std.testing.expect(truncation.changed);
}

test "compatibility publication preserves target failures and rejects alias" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realpathAlloc(
        std.testing.allocator,
        ".",
    );
    defer std.testing.allocator.free(root);
    const invalid_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "invalid.safetensors" },
    );
    defer std.testing.allocator.free(invalid_path);
    const target_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "model.glacier" },
    );
    defer std.testing.allocator.free(target_path);
    const source_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "source.safetensors" },
    );
    defer std.testing.allocator.free(source_path);

    {
        const invalid = try temporary.dir.createFile(
            "invalid.safetensors",
            .{},
        );
        defer invalid.close();
        try invalid.writeAll("invalid");
    }
    {
        const target = try temporary.dir.createFile(
            "model.glacier",
            .{},
        );
        defer target.close();
        try target.writeAll("keep");
    }
    try std.testing.expectError(
        ConvertError.NotSafetensors,
        convertSafetensors(
            std.testing.allocator,
            invalid_path,
            target_path,
            .{},
        ),
    );
    const retained = try temporary.dir.readFileAlloc(
        std.testing.allocator,
        "model.glacier",
        16,
    );
    defer std.testing.allocator.free(retained);
    try std.testing.expectEqualStrings("keep", retained);

    {
        const source = try temporary.dir.createFile(
            "source.safetensors",
            .{ .read = true },
        );
        defer source.close();
        const payload = testF32PayloadV1(4);
        _ = try writeTestSafetensorsV1(
            source,
            "F32",
            4,
            &payload,
        );
    }
    const source_size = (try temporary.dir.statFile(
        "source.safetensors",
    )).size;
    try std.testing.expectError(
        ConvertError.SourceOutputAlias,
        convertSafetensors(
            std.testing.allocator,
            source_path,
            source_path,
            .{},
        ),
    );
    try std.testing.expectEqual(
        source_size,
        (try temporary.dir.statFile("source.safetensors")).size,
    );

    _ = try convertSafetensors(
        std.testing.allocator,
        source_path,
        target_path,
        .{},
    );
    var reader = try fmt.FileReader.open(
        std.testing.allocator,
        target_path,
    );
    defer reader.close();
    try std.testing.expectEqual(@as(usize, 1), reader.pages.len);
}

test "raw maximum page uses a bounded 64 KiB source workspace" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const payload = try std.testing.allocator.alloc(
        u8,
        fmt.PAGE_SIZE_BYTES,
    );
    defer std.testing.allocator.free(payload);
    @memset(payload, 0);
    const input = try temporary.dir.createFile(
        "maximum-raw.safetensors",
        .{ .read = true },
    );
    defer input.close();
    _ = try writeTestSafetensorsV1(
        input,
        "F32",
        fmt.PAGE_SIZE_BYTES / @sizeOf(f32),
        payload,
    );
    const output = try temporary.dir.createFile(
        "maximum-raw.glacier",
        .{ .read = true },
    );
    defer output.close();
    const result = try convertSafetensorsFilesV1(
        std.testing.allocator,
        input,
        output,
        .{},
    );
    try std.testing.expectEqual(
        @as(u64, verification_chunk_bytes),
        result.conversion_workspace_bytes_peak,
    );
}
