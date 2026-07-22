//! Glacier model file format — read/write per docs/FORMAT_SPEC.md.
//!
//! Layout (all little-endian):
//!
//!   ┌──────────────────────────────────────────────────────────┐
//!   │ Header  (256 bytes, fixed)                               │
//!   ├──────────────────────────────────────────────────────────┤
//!   │ Metadata blob  (JSON, header.meta_len bytes)             │
//!   ├──────────────────────────────────────────────────────────┤
//!   │ Page index    (header.num_pages × sizeof(PageEntry))     │
//!   ├──────────────────────────────────────────────────────────┤
//!   │ Page data     (concatenated, offsets in index)           │
//!   └──────────────────────────────────────────────────────────┘
//!
//! Status: draft v0.1. Will break before 1.0.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const accelerated_crc32 = @import("../crc32.zig");

pub const MAGIC: [4]u8 = .{ 'G', 'L', 'A', 'C' };
pub const VERSION: u16 = 1;
pub const HEADER_SIZE: u16 = 256;
/// Unpacked (FP16-equivalent) weight bytes per page. log2 = 18.
pub const PAGE_SIZE_BYTES: u64 = 1 << 18;
pub const PAGE_ENTRY_SIZE: usize = 64;

/// Precision tag, same values as core.Precision but stored as a raw byte
/// so the file format does not depend on the Zig enum tag assignment.
pub const StoredPrecision = core.Precision;

pub const TensorKind = enum(u32) {
    embedding = 0,
    attn_q = 1,
    attn_k = 2,
    attn_v = 3,
    attn_o = 4,
    mlp_up = 5,
    mlp_down = 6,
    mlp_gate = 7,
    input_norm = 8, // input_layernorm
    lm_head = 9,
    final_norm = 10, // global model.norm.weight
    post_attn_norm = 11, // post_attention_layernorm
    attn_q_bias = 12,
    attn_k_bias = 13,
    attn_v_bias = 14,
    attn_o_bias = 15,
    other = 255,
};

/// 256-byte on-disk header.
pub const Header = struct {
    magic: [4]u8 = MAGIC,
    version: u16 = VERSION,
    header_size: u16 = HEADER_SIZE,
    meta_offset: u64,
    meta_len: u64,
    num_pages: u64,
    page_index_offset: u64,
    page_data_offset: u64,
    page_size_log2: u32 = 18,
    reserved: u32 = 0,

    pub fn packedSize() usize {
        // magic(4) + version(2) + header_size(2) + 5×u64(40) + page_size_log2(4) + reserved(4) = 56
        return 4 + 2 + 2 + 8 * 5 + 4 + 4;
    }

    pub fn writeTo(self: Header, w: anytype) !void {
        try w.writeAll(&self.magic);
        try w.writeInt(u16, self.version, .little);
        try w.writeInt(u16, self.header_size, .little);
        try w.writeInt(u64, self.meta_offset, .little);
        try w.writeInt(u64, self.meta_len, .little);
        try w.writeInt(u64, self.num_pages, .little);
        try w.writeInt(u64, self.page_index_offset, .little);
        try w.writeInt(u64, self.page_data_offset, .little);
        try w.writeInt(u32, self.page_size_log2, .little);
        try w.writeInt(u32, self.reserved, .little);
        // Pad up to HEADER_SIZE.
        const written: usize = packedSize();
        const pad_len: usize = HEADER_SIZE - written;
        var pad_buf: [HEADER_SIZE]u8 = undefined;
        @memset(pad_buf[0..pad_len], 0);
        try w.writeAll(pad_buf[0..pad_len]);
    }

    pub fn readFrom(r: anytype) !Header {
        var magic: [4]u8 = undefined;
        try r.readNoEof(&magic);
        if (!std.mem.eql(u8, &magic, &MAGIC)) return error.BadMagic;
        const version = try r.readInt(u16, .little);
        const header_size = try r.readInt(u16, .little);
        const meta_offset = try r.readInt(u64, .little);
        const meta_len = try r.readInt(u64, .little);
        const num_pages = try r.readInt(u64, .little);
        const page_index_offset = try r.readInt(u64, .little);
        const page_data_offset = try r.readInt(u64, .little);
        const page_size_log2 = try r.readInt(u32, .little);
        const reserved = try r.readInt(u32, .little);
        // Skip padding to HEADER_SIZE.
        const consumed: usize = packedSize();
        var pad: [HEADER_SIZE]u8 = undefined;
        try r.readNoEof(pad[0 .. HEADER_SIZE - consumed]);
        return .{
            .magic = magic,
            .version = version,
            .header_size = header_size,
            .meta_offset = meta_offset,
            .meta_len = meta_len,
            .num_pages = num_pages,
            .page_index_offset = page_index_offset,
            .page_data_offset = page_data_offset,
            .page_size_log2 = page_size_log2,
            .reserved = reserved,
        };
    }
};

/// 64-byte page index entry. See FORMAT_SPEC.md.
pub const PageEntry = struct {
    page_id: u64,
    layer_idx: u32,
    tensor_kind: TensorKind,
    row_start: u64,
    row_end: u64,
    precision: StoredPrecision,
    quant_group: u8, // 0 = per-channel
    crc32: u32,
    data_offset: u64,
    data_len: u64,

    pub fn writeTo(self: PageEntry, w: anytype) !void {
        try w.writeInt(u64, self.page_id, .little);
        try w.writeInt(u32, self.layer_idx, .little);
        try w.writeInt(u32, @intFromEnum(self.tensor_kind), .little);
        try w.writeInt(u64, self.row_start, .little);
        try w.writeInt(u64, self.row_end, .little);
        try w.writeInt(u8, @intFromEnum(self.precision), .little);
        try w.writeInt(u8, self.quant_group, .little);
        try w.writeInt(u16, 0, .little); // reserved
        try w.writeInt(u64, self.data_offset, .little);
        try w.writeInt(u64, self.data_len, .little);
        try w.writeInt(u32, self.crc32, .little);
        try w.writeInt(u32, 0, .little); // reserved2
        try w.writeInt(u32, 0, .little); // reserved3 (pad to 64 bytes)
    }

    pub fn readFrom(r: anytype) !PageEntry {
        const page_id = try r.readInt(u64, .little);
        const layer_idx = try r.readInt(u32, .little);
        const tensor_kind_raw = try r.readInt(u32, .little);
        const row_start = try r.readInt(u64, .little);
        const row_end = try r.readInt(u64, .little);
        const precision_raw = try r.readInt(u8, .little);
        const quant_group = try r.readInt(u8, .little);
        _ = try r.readInt(u16, .little); // reserved
        const data_offset = try r.readInt(u64, .little);
        const data_len = try r.readInt(u64, .little);
        const crc32 = try r.readInt(u32, .little);
        _ = try r.readInt(u32, .little); // reserved2
        _ = try r.readInt(u32, .little); // reserved3

        const tensor_kind = std.meta.intToEnum(TensorKind, tensor_kind_raw) catch .other;
        const precision = std.meta.intToEnum(StoredPrecision, precision_raw) catch
            return error.BadPrecision;
        return .{
            .page_id = page_id,
            .layer_idx = layer_idx,
            .tensor_kind = tensor_kind,
            .row_start = row_start,
            .row_end = row_end,
            .precision = precision,
            .quant_group = quant_group,
            .crc32 = crc32,
            .data_offset = data_offset,
            .data_len = data_len,
        };
    }
};

/// Convenience for reading a whole file back into memory.
pub const FileReader = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    header: Header,
    pages: []PageEntry,
    meta_bytes: []u8,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !FileReader {
        const file = try std.fs.cwd().openFile(path, .{});
        errdefer file.close();
        const header = blk: {
            var hbuf: [HEADER_SIZE]u8 = undefined;
            const n = try file.read(&hbuf);
            if (n != HEADER_SIZE) return error.TruncatedHeader;
            var fbs = std.io.fixedBufferStream(&hbuf);
            break :blk try Header.readFrom(fbs.reader());
        };

        // Metadata blob.
        const meta_bytes = try allocator.alloc(u8, @intCast(header.meta_len));
        errdefer allocator.free(meta_bytes);
        const meta_n = try file.preadAll(meta_bytes, header.meta_offset);
        if (meta_n != header.meta_len) return error.TruncatedMeta;

        // Page index.
        const num_pages = std.math.cast(usize, header.num_pages) orelse
            return error.IndexTooLarge;
        const index_len = std.math.mul(usize, num_pages, PAGE_ENTRY_SIZE) catch
            return error.IndexTooLarge;
        const pages = try allocator.alloc(PageEntry, num_pages);
        errdefer allocator.free(pages);
        const index_bytes = try allocator.alloc(u8, index_len);
        defer allocator.free(index_bytes);
        const index_n = try file.preadAll(index_bytes, header.page_index_offset);
        if (index_n != index_bytes.len) return error.TruncatedIndex;
        for (pages, 0..) |*p, idx| {
            const at = idx * PAGE_ENTRY_SIZE;
            var fbs = std.io.fixedBufferStream(index_bytes[at .. at + PAGE_ENTRY_SIZE]);
            p.* = try PageEntry.readFrom(fbs.reader());
        }

        return .{
            .allocator = allocator,
            .file = file,
            .header = header,
            .pages = pages,
            .meta_bytes = meta_bytes,
        };
    }

    pub fn close(self: *FileReader) void {
        self.file.close();
        self.allocator.free(self.pages);
        self.allocator.free(self.meta_bytes);
    }

    /// Read a page's payload into caller-provided buffer. Verifies CRC32.
    pub fn readPage(self: *FileReader, page: PageEntry, dst: []u8) !void {
        if (dst.len < page.data_len) return error.BufferTooSmall;
        const got = try self.file.preadAll(dst[0..@intCast(page.data_len)], page.data_offset);
        if (got != page.data_len) return error.TruncatedPage;
        const got_crc = accelerated_crc32.hash(dst[0..@intCast(page.data_len)]);
        if (got_crc != page.crc32) return error.CrcMismatch;
    }

    /// Hint the OS to begin loading one coalesced tensor range into the page
    /// cache. Unlike mmap + madvise, range advice does not add a file-backed
    /// mapping to process RSS. Best-effort: unsupported platforms and errors
    /// are intentionally ignored.
    pub fn prefetchPages(self: *FileReader, pages: []const PageEntry) void {
        if (pages.len == 0) return;
        var range_start: u64 = std.math.maxInt(u64);
        var range_end: u64 = 0;
        for (pages) |p| {
            const page_end = std.math.add(u64, p.data_offset, p.data_len) catch continue;
            range_start = @min(range_start, p.data_offset);
            range_end = @max(range_end, page_end);
        }
        if (range_end <= range_start) return;

        if (comptime builtin.os.tag == .macos) {
            // F_RDADVISE issues asynchronous read-ahead without copying bytes
            // into userspace. Split ranges because ra_count is a signed int.
            const Radvisory = extern struct {
                ra_offset: i64,
                ra_count: i32,
            };
            const f_rdadvise: i32 = 44;
            const max_chunk: u64 = std.math.maxInt(i32);
            var cursor = range_start;
            while (cursor < range_end) {
                const chunk = @min(range_end - cursor, max_chunk);
                const offset = std.math.cast(i64, cursor) orelse return;
                var advisory = Radvisory{
                    .ra_offset = offset,
                    .ra_count = @intCast(chunk),
                };
                _ = std.posix.system.fcntl(
                    self.file.handle,
                    f_rdadvise,
                    &advisory,
                );
                cursor += chunk;
            }
        } else if (comptime builtin.os.tag == .linux) {
            const offset = std.math.cast(i64, range_start) orelse return;
            const length = std.math.cast(i64, range_end - range_start) orelse return;
            _ = std.os.linux.fadvise(
                self.file.handle,
                offset,
                length,
                std.os.linux.POSIX_FADV.WILLNEED,
            );
        }
    }

    /// Read a page's raw payload (owned by caller). Verifies CRC32.
    pub fn readPageAlloc(self: *FileReader, page: PageEntry) ![]u8 {
        const buf = try self.allocator.alloc(u8, @intCast(page.data_len));
        errdefer self.allocator.free(buf);
        try self.readPage(page, buf);
        return buf;
    }

    /// Read a page and, if it is quantized, dequantize it back to `DstDType`.
    /// Returns owned memory (properly aligned for DstDType). For raw pages the
    /// bytes are copied into a DstDType-aligned buffer so the caller can free
    /// the result without alignment bookkeeping.
    pub fn readPageDequant(
        self: *FileReader,
        comptime DstDType: type,
        page: PageEntry,
    ) ![]DstDType {
        const raw = try self.readPageAlloc(page);
        defer self.allocator.free(raw);
        const layout = @import("qio.zig").detectLayout(raw);
        switch (layout) {
            .raw => {
                if (page.data_len % @sizeOf(DstDType) != 0) return error.SizeMismatch;
                const len = page.data_len / @sizeOf(DstDType);
                const out = try self.allocator.alloc(DstDType, len);
                // Reinterpret bytes into DstDType (little-endian host assumption).
                @memcpy(@as([*]u8, @ptrCast(out.ptr))[0..page.data_len], raw);
                return out;
            },
            .quantized => {
                return try @import("qio.zig").decodePage(DstDType, self.allocator, raw);
            },
        }
    }
};

// --------------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------------

test "header round-trip" {
    const h = Header{
        .meta_offset = 256,
        .meta_len = 16,
        .num_pages = 3,
        .page_index_offset = 272,
        .page_data_offset = 464,
    };
    var buf: [HEADER_SIZE]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try h.writeTo(fbs.writer());
    try std.testing.expectEqual(@as(usize, HEADER_SIZE), fbs.pos);

    var read_fbs = std.io.fixedBufferStream(&buf);
    const back = try Header.readFrom(read_fbs.reader());
    try std.testing.expectEqual(h.num_pages, back.num_pages);
    try std.testing.expectEqual(h.meta_offset, back.meta_offset);
    try std.testing.expectEqual(h.page_data_offset, back.page_data_offset);
}

test "page entry round-trip" {
    const e = PageEntry{
        .page_id = 42,
        .layer_idx = 7,
        .tensor_kind = .mlp_up,
        .row_start = 0,
        .row_end = 128,
        .precision = .int4,
        .quant_group = 32,
        .crc32 = 0xDEADBEEF,
        .data_offset = 1024,
        .data_len = 512,
    };
    var buf: [PAGE_ENTRY_SIZE]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try e.writeTo(fbs.writer());
    try std.testing.expectEqual(@as(usize, PAGE_ENTRY_SIZE), fbs.pos);

    var read_fbs = std.io.fixedBufferStream(&buf);
    const back = try PageEntry.readFrom(read_fbs.reader());
    try std.testing.expectEqual(e.page_id, back.page_id);
    try std.testing.expectEqual(e.layer_idx, back.layer_idx);
    try std.testing.expectEqual(e.tensor_kind, back.tensor_kind);
    try std.testing.expectEqual(e.precision, back.precision);
    try std.testing.expectEqual(e.crc32, back.crc32);
}

test "crc32 matches std" {
    const data = "hello glacier";
    try std.testing.expectEqual(std.hash.Crc32.hash(data), accelerated_crc32.hash(data));
}
