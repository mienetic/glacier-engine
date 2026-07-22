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
    NotSafetensors,
    OutOfMemory,
    JsonError,
};

/// Parse the header of a safetensors file from a buffer containing at
/// least the first 8 + header_len bytes. Returns tensor metadata.
pub fn parseHeader(
    allocator: std.mem.Allocator,
    file_bytes: []const u8,
) ParseError!SafetensorsFile {
    if (file_bytes.len < 8) return ParseError.BadHeaderLength;
    const header_len = std.mem.readInt(u64, file_bytes[0..8], .little);
    if (header_len > file_bytes.len - 8) return ParseError.BadHeaderLength;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const json_bytes = file_bytes[8 .. 8 + header_len];
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
        if (std.mem.eql(u8, kv.key_ptr.*, "__metadata__")) continue;
        count += 1;
    }

    var tensors = try arena_alloc.alloc(TensorInfo, count);

    var i: usize = 0;
    it = root.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.key_ptr.*, "__metadata__")) continue;
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
            break :blk .{ .start = @as(u64, @intCast(a.integer)), .end = @as(u64, @intCast(b.integer)) };
        };
        const shape: []const u64 = blk: {
            const v = obj.object.get("shape") orelse return ParseError.JsonError;
            if (v != .array) return ParseError.JsonError;
            const out = try arena_alloc.alloc(u64, v.array.items.len);
            for (v.array.items, 0..) |dim, k| {
                if (dim != .integer) return ParseError.JsonError;
                out[k] = @intCast(dim.integer);
            }
            break :blk out;
        };

        tensors[i] = .{
            .name = kv.key_ptr.*,
            .dtype = parseDType(dtype_str) catch .unknown,
            .byte_length = offsets.end - offsets.start,
            .data_offset = offsets.start,
            .shape = shape,
        };
        i += 1;
    }

    return .{
        .allocator = allocator,
        .arena = arena,
        .header_json = owned,
        .tensors = tensors,
        .data_region_start = 8 + header_len,
    };
}

fn parseDType(s: []const u8) ParseError!DType {
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
    return .unknown;
}

// --------------------------------------------------------------------------
// Test: build a tiny safetensors blob in-memory, parse it back.
// --------------------------------------------------------------------------

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
