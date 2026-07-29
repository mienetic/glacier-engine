//! Minimal safetensors reader.
//!
//! Only reads what the converter needs: the JSON header (first 8 bytes
//! give the header length as little-endian u64), tensor dtype/shape, and
//! the byte ranges in the file body. We do NOT decode every dtype — the
//! converter only needs FP16/BF16/FP32 source weights, which it then
//! slices into Glacier pages.
//!
//! Spec: https://github.com/huggingface/safetensors

const std = @import("std");

/// Safetensors reserves at most 100 MB for its JSON header. Enforcing the
/// format limit before allocation keeps hostile length prefixes from turning
/// admission into an unbounded memory request.
pub const MAX_HEADER_BYTES: u64 = 100_000_000;

pub const DType = enum {
    f64,
    f32,
    f16,
    bf16,
    i64,
    i32,
    i16,
    i8,
    u8,
    bool,
    unknown,
};

pub const TensorInfo = struct {
    name: []const u8, // borrowed from header json, valid until reader deinit
    dtype: DType,
    /// flat byte length of this tensor's payload in the file.
    byte_length: u64,
    /// offset from the start of the data region (after the header).
    data_offset: u64,
    shape: []const u64, // borrowed
};

pub const SafetensorsFile = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    /// Raw JSON header bytes (owned by arena). TensorInfo slices point into here.
    header_json: []u8,
    tensors: []TensorInfo,
    /// Offset in the file where the data region starts (= header_len + 8).
    data_region_start: u64,

    pub fn deinit(self: *SafetensorsFile) void {
        self.arena.deinit();
    }
};

pub const ParseError = error{
    BadHeaderLength,
    HeaderTooLarge,
    NotSafetensors,
    InvalidTensor,
    UnsupportedDType,
    NonContiguousData,
    OutOfMemory,
    JsonError,
};

/// Parse a complete in-memory Safetensors file.
pub fn parseHeader(
    allocator: std.mem.Allocator,
    file_bytes: []const u8,
) ParseError!SafetensorsFile {
    return parseHeaderPrefix(
        allocator,
        file_bytes,
        @intCast(file_bytes.len),
    );
}

/// Parse tensor metadata from only the `8 + header_len` byte prefix while
/// validating all tensor offsets against the complete descriptor length.
/// `file_size` is the byte length of the source file represented by the prefix.
pub fn parseHeaderPrefix(
    allocator: std.mem.Allocator,
    header_prefix: []const u8,
    file_size: u64,
) ParseError!SafetensorsFile {
    if (header_prefix.len < 8) return ParseError.BadHeaderLength;
    const header_len = std.mem.readInt(
        u64,
        header_prefix[0..8],
        .little,
    );
    if (header_len > MAX_HEADER_BYTES) return ParseError.HeaderTooLarge;
    const header_len_usize = std.math.cast(usize, header_len) orelse
        return ParseError.BadHeaderLength;
    const data_region_start_usize = std.math.add(
        usize,
        8,
        header_len_usize,
    ) catch return ParseError.BadHeaderLength;
    if (data_region_start_usize > header_prefix.len)
        return ParseError.BadHeaderLength;
    const data_region_start: u64 = std.math.cast(
        u64,
        data_region_start_usize,
    ) orelse return ParseError.BadHeaderLength;
    if (data_region_start > file_size)
        return ParseError.BadHeaderLength;
    const data_region_len = file_size - data_region_start;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const json_bytes = header_prefix[8..data_region_start_usize];
    // Safetensors framing is stricter than generic JSON: the first header
    // byte is the object opener and optional alignment padding after the
    // document consists only of ASCII spaces. The general JSON parser accepts
    // leading and trailing tabs/newlines, so enforce the wire contract before
    // handing it the slice.
    if (json_bytes.len == 0 or json_bytes[0] != '{')
        return ParseError.JsonError;
    var document_end = json_bytes.len;
    while (document_end != 0 and
        json_bytes[document_end - 1] == ' ')
    {
        document_end -= 1;
    }
    if (document_end == 0 or json_bytes[document_end - 1] != '}')
        return ParseError.JsonError;
    // Make a copy we own so tensor names stay alive after the caller's
    // buffer goes away.
    const owned = try arena_alloc.dupe(u8, json_bytes);

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena_alloc, owned, .{}) catch
        return ParseError.JsonError;
    const root = parsed;
    if (root != .object) return ParseError.JsonError;

    // First pass: count tensors.
    var count: usize = 0;
    var it = root.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.key_ptr.*, "__metadata__")) {
            try validateMetadata(kv.value_ptr.*);
            continue;
        }
        count += 1;
    }

    var tensors = try arena_alloc.alloc(TensorInfo, count);

    var i: usize = 0;
    it = root.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.key_ptr.*, "__metadata__")) {
            // Validated during the counting pass.
            continue;
        }
        const obj = kv.value_ptr.*;
        if (obj != .object) return ParseError.JsonError;

        const dtype_str = blk: {
            const v = obj.object.get("dtype") orelse return ParseError.JsonError;
            if (v != .string) return ParseError.JsonError;
            break :blk v.string;
        };
        const offsets = blk: {
            const v = obj.object.get("data_offsets") orelse return ParseError.JsonError;
            if (v != .array or v.array.items.len != 2) return ParseError.JsonError;
            const a = v.array.items[0];
            const b = v.array.items[1];
            if (a != .integer or b != .integer) return ParseError.JsonError;
            if (a.integer < 0 or b.integer < 0)
                return ParseError.InvalidTensor;
            const start: u64 = @intCast(a.integer);
            const end: u64 = @intCast(b.integer);
            if (end < start or end > data_region_len)
                return ParseError.InvalidTensor;
            break :blk .{ .start = start, .end = end };
        };
        const shape: []const u64 = blk: {
            const v = obj.object.get("shape") orelse return ParseError.JsonError;
            if (v != .array) return ParseError.JsonError;
            const out = try arena_alloc.alloc(u64, v.array.items.len);
            for (v.array.items, 0..) |dim, k| {
                if (dim != .integer) return ParseError.JsonError;
                if (dim.integer < 0) return ParseError.InvalidTensor;
                out[k] = @intCast(dim.integer);
            }
            break :blk out;
        };
        const dtype = parseDType(dtype_str) orelse
            return ParseError.UnsupportedDType;
        var element_count: u64 = 1;
        for (shape) |extent| {
            element_count = std.math.mul(u64, element_count, extent) catch
                return ParseError.InvalidTensor;
        }
        const expected_bytes = std.math.mul(
            u64,
            element_count,
            dtypeByteSize(dtype),
        ) catch return ParseError.InvalidTensor;
        const byte_length = offsets.end - offsets.start;
        if (byte_length != expected_bytes) return ParseError.InvalidTensor;

        tensors[i] = .{
            .name = kv.key_ptr.*,
            .dtype = dtype,
            .byte_length = byte_length,
            .data_offset = offsets.start,
            .shape = shape,
        };
        i += 1;
    }

    // The safetensors data region must be covered exactly once. Sorting the
    // borrowed metadata by physical offset makes overlap, holes, and trailing
    // unindexed bytes fail closed before the converter can read the payload.
    std.sort.heap(TensorInfo, tensors, {}, struct {
        fn lessThan(_: void, a: TensorInfo, b: TensorInfo) bool {
            if (a.data_offset != b.data_offset)
                return a.data_offset < b.data_offset;
            if (a.byte_length != b.byte_length)
                return a.byte_length < b.byte_length;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    var expected_offset: u64 = 0;
    for (tensors) |tensor| {
        if (tensor.data_offset != expected_offset)
            return ParseError.NonContiguousData;
        expected_offset = std.math.add(
            u64,
            expected_offset,
            tensor.byte_length,
        ) catch return ParseError.InvalidTensor;
    }
    if (expected_offset != data_region_len)
        return ParseError.NonContiguousData;

    return .{
        .allocator = allocator,
        .arena = arena,
        .header_json = owned,
        .tensors = tensors,
        .data_region_start = data_region_start,
    };
}

fn validateMetadata(value: std.json.Value) ParseError!void {
    if (value != .object) return ParseError.JsonError;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) return ParseError.JsonError;
    }
}

fn parseDType(s: []const u8) ?DType {
    if (std.mem.eql(u8, s, "F64")) return .f64;
    if (std.mem.eql(u8, s, "F32")) return .f32;
    if (std.mem.eql(u8, s, "F16")) return .f16;
    if (std.mem.eql(u8, s, "BF16")) return .bf16;
    if (std.mem.eql(u8, s, "I64")) return .i64;
    if (std.mem.eql(u8, s, "I32")) return .i32;
    if (std.mem.eql(u8, s, "I16")) return .i16;
    if (std.mem.eql(u8, s, "I8")) return .i8;
    if (std.mem.eql(u8, s, "U8")) return .u8;
    if (std.mem.eql(u8, s, "BOOL")) return .bool;
    return null;
}

fn dtypeByteSize(dtype: DType) u64 {
    return switch (dtype) {
        .f64, .i64 => 8,
        .f32, .i32 => 4,
        .f16, .bf16, .i16 => 2,
        .i8, .u8, .bool => 1,
        .unknown => unreachable,
    };
}

// --------------------------------------------------------------------------
// Test: build a tiny safetensors blob in-memory, parse it back.
// --------------------------------------------------------------------------

fn expectParseError(
    expected: ParseError,
    json: []const u8,
    data_len: usize,
) !void {
    const total = std.math.add(usize, 8 + json.len, data_len) catch
        return error.OutOfMemory;
    const buf = try std.testing.allocator.alloc(u8, total);
    defer std.testing.allocator.free(buf);
    std.mem.writeInt(u64, buf[0..8], @intCast(json.len), .little);
    @memcpy(buf[8 .. 8 + json.len], json);
    @memset(buf[8 + json.len ..], 0);
    try std.testing.expectError(
        expected,
        parseHeader(std.testing.allocator, buf),
    );
}

test "parse minimal safetensors header" {
    // Header: {"t":{"dtype":"F32","shape":[2,3],"data_offsets":[0,24]}}
    const json =
        \\{"t":{"dtype":"F32","shape":[2,3],"data_offsets":[0,24]},"__metadata__":{"format":"pt"}}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const total = 8 + json.len + 24;
    const buf = try arena.allocator().alloc(u8, total);
    std.mem.writeInt(u64, buf[0..8], @intCast(json.len), .little);
    @memcpy(buf[8 .. 8 + json.len], json);
    @memset(buf[8 + json.len ..], 0);

    var st = try parseHeader(std.testing.allocator, buf);
    defer st.deinit();
    try std.testing.expectEqual(@as(usize, 1), st.tensors.len);
    try std.testing.expectEqual(DType.f32, st.tensors[0].dtype);
    try std.testing.expectEqual(@as(u64, 24), st.tensors[0].byte_length);
    // shape borrow check
    try std.testing.expectEqual(@as(usize, 2), st.tensors[0].shape.len);
    try std.testing.expectEqual(@as(u64, 8 + json.len), st.data_region_start);
}

test "header-prefix parsing validates against the complete file size" {
    const json =
        \\{"t":{"dtype":"F32","shape":[2,3],"data_offsets":[0,24]},"__metadata__":{"format":"pt"}}
    ;
    var prefix: [8 + json.len]u8 = undefined;
    std.mem.writeInt(u64, prefix[0..8], @intCast(json.len), .little);
    @memcpy(prefix[8..], json);

    var parsed = try parseHeaderPrefix(
        std.testing.allocator,
        &prefix,
        prefix.len + 24,
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.tensors.len);
    try std.testing.expectEqual(@as(u64, 24), parsed.tensors[0].byte_length);
    try std.testing.expectEqual(
        @as(u64, prefix.len),
        parsed.data_region_start,
    );

    try std.testing.expectError(
        ParseError.BadHeaderLength,
        parseHeaderPrefix(
            std.testing.allocator,
            prefix[0 .. prefix.len - 1],
            prefix.len + 24,
        ),
    );
    try std.testing.expectError(
        ParseError.BadHeaderLength,
        parseHeaderPrefix(
            std.testing.allocator,
            &prefix,
            prefix.len - 1,
        ),
    );
    try std.testing.expectError(
        ParseError.InvalidTensor,
        parseHeaderPrefix(
            std.testing.allocator,
            &prefix,
            prefix.len + 23,
        ),
    );
}

test "strict safetensors rejects hostile integer and dtype domains" {
    try expectParseError(
        ParseError.InvalidTensor,
        \\{"t":{"dtype":"F32","shape":[1],"data_offsets":[-1,4]}}
    ,
        4,
    );
    try expectParseError(
        ParseError.InvalidTensor,
        \\{"t":{"dtype":"F32","shape":[1],"data_offsets":[4,0]}}
    ,
        4,
    );
    try expectParseError(
        ParseError.InvalidTensor,
        \\{"t":{"dtype":"F32","shape":[1],"data_offsets":[0,8]}}
    ,
        4,
    );
    try expectParseError(
        ParseError.InvalidTensor,
        \\{"t":{"dtype":"F32","shape":[-1],"data_offsets":[0,4]}}
    ,
        4,
    );
    try expectParseError(
        ParseError.InvalidTensor,
        \\{"t":{"dtype":"F32","shape":[2],"data_offsets":[0,4]}}
    ,
        4,
    );
    try expectParseError(
        ParseError.InvalidTensor,
        \\{"t":{"dtype":"F64","shape":[9223372036854775807,2],"data_offsets":[0,0]}}
    ,
        0,
    );
    try expectParseError(
        ParseError.UnsupportedDType,
        \\{"t":{"dtype":"F8_E4M3","shape":[4],"data_offsets":[0,4]}}
    ,
        4,
    );
}

test "strict safetensors bounds and validates metadata" {
    var oversized_prefix: [8]u8 = undefined;
    std.mem.writeInt(
        u64,
        &oversized_prefix,
        MAX_HEADER_BYTES + 1,
        .little,
    );
    try std.testing.expectError(
        ParseError.HeaderTooLarge,
        parseHeader(std.testing.allocator, &oversized_prefix),
    );
    try expectParseError(
        ParseError.JsonError,
        \\{"t":{"dtype":"F32","shape":[1],"data_offsets":[0,4]},"__metadata__":[]}
    ,
        4,
    );
    try expectParseError(
        ParseError.JsonError,
        \\{"t":{"dtype":"F32","shape":[1],"data_offsets":[0,4]},"__metadata__":{"format":1}}
    ,
        4,
    );
}

test "strict safetensors enforces JSON framing and space-only padding" {
    try expectParseError(
        ParseError.JsonError,
        "\n" ++
            \\{"t":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}
        ,
        4,
    );
    try expectParseError(
        ParseError.JsonError,
        \\{"t":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}
    ++ "\n",
        4,
    );
    try expectParseError(
        ParseError.JsonError,
        \\{"t":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}
    ++ "\t ",
        4,
    );

    const padded =
        \\{"t":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}
    ++ "   ";
    const total = 8 + padded.len + 4;
    const bytes = try std.testing.allocator.alloc(u8, total);
    defer std.testing.allocator.free(bytes);
    std.mem.writeInt(u64, bytes[0..8], padded.len, .little);
    @memcpy(bytes[8 .. 8 + padded.len], padded);
    @memset(bytes[8 + padded.len ..], 0);
    var parsed = try parseHeader(std.testing.allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.tensors.len);
}

test "strict safetensors requires exact single coverage of the data region" {
    try expectParseError(
        ParseError.NonContiguousData,
        \\{"a":{"dtype":"F32","shape":[1],"data_offsets":[0,4]},"b":{"dtype":"F32","shape":[1],"data_offsets":[8,12]}}
    ,
        12,
    );
    try expectParseError(
        ParseError.NonContiguousData,
        \\{"a":{"dtype":"F32","shape":[2],"data_offsets":[0,8]},"b":{"dtype":"F32","shape":[1],"data_offsets":[4,8]}}
    ,
        8,
    );
    try expectParseError(
        ParseError.NonContiguousData,
        \\{"a":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}
    ,
        8,
    );
}

test "strict safetensors orders admitted tensors by physical payload" {
    const json =
        \\{"later":{"dtype":"F32","shape":[1],"data_offsets":[4,8]},"first":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}
    ;
    const total = 8 + json.len + 8;
    const buf = try std.testing.allocator.alloc(u8, total);
    defer std.testing.allocator.free(buf);
    std.mem.writeInt(u64, buf[0..8], @intCast(json.len), .little);
    @memcpy(buf[8 .. 8 + json.len], json);
    @memset(buf[8 + json.len ..], 0);

    var parsed = try parseHeader(std.testing.allocator, buf);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("first", parsed.tensors[0].name);
    try std.testing.expectEqualStrings("later", parsed.tensors[1].name);
}
