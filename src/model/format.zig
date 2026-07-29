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
const qio = @import("qio.zig");

pub const MAGIC: [4]u8 = .{ 'G', 'L', 'A', 'C' };
pub const VERSION: u16 = 1;
pub const format_abi: u64 = 0x474c_4143_0000_0001;
pub const HEADER_SIZE: u16 = 256;
/// Unpacked (FP16-equivalent) weight bytes per page. log2 = 18.
pub const PAGE_SIZE_BYTES: u64 = 1 << 18;
pub const PAGE_SIZE_LOG2: u32 = 18;
pub const PAGE_ENTRY_SIZE: usize = 64;
pub const STREAM_BUFFER_SIZE: usize = 64 * 1024;
/// V1 admission bounds keep metadata/index parsing predictable for untrusted
/// files. One million maximum-sized pages can describe 256 GiB of raw data.
pub const MAX_METADATA_BYTES_V1: u64 = 16 * 1024 * 1024;
pub const MAX_PAGE_COUNT_V1: u64 = 1024 * 1024;

pub const ContainerIdentityV1 = struct {
    container_bytes: u64,
    container_sha256: [32]u8,
};

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
    page_size_log2: u32 = PAGE_SIZE_LOG2,
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
        if (version != VERSION) return error.BadVersion;
        const header_size = try r.readInt(u16, .little);
        if (header_size != HEADER_SIZE) return error.BadHeaderSize;
        const meta_offset = try r.readInt(u64, .little);
        const meta_len = try r.readInt(u64, .little);
        const num_pages = try r.readInt(u64, .little);
        const page_index_offset = try r.readInt(u64, .little);
        const page_data_offset = try r.readInt(u64, .little);
        const page_size_log2 = try r.readInt(u32, .little);
        if (page_size_log2 != PAGE_SIZE_LOG2) return error.BadPageSize;
        const reserved = try r.readInt(u32, .little);
        if (reserved != 0) return error.BadReservedField;
        const consumed: usize = packedSize();
        var padding: [HEADER_SIZE]u8 = undefined;
        const padding_bytes = padding[0 .. HEADER_SIZE - consumed];
        try r.readNoEof(padding_bytes);
        if (!allZero(padding_bytes)) return error.BadReservedField;
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
    quant_group: u8, // 0 = raw/unquantized; nonzero = quantization group
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
        const reserved = try r.readInt(u16, .little);
        const data_offset = try r.readInt(u64, .little);
        const data_len = try r.readInt(u64, .little);
        const crc32 = try r.readInt(u32, .little);
        const reserved2 = try r.readInt(u32, .little);
        const reserved3 = try r.readInt(u32, .little);
        if (reserved != 0 or reserved2 != 0 or reserved3 != 0)
            return error.BadReservedField;

        const tensor_kind = std.meta.intToEnum(TensorKind, tensor_kind_raw) catch
            return error.BadTensorKind;
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

const FileOwnership = enum {
    owned,
    borrowed,
};

const HeaderLayoutV1 = struct {
    meta_end: u64,
    index_bytes: u64,
    index_end: u64,
};

fn validateHeaderLayoutV1(
    header: Header,
    file_size: u64,
) !HeaderLayoutV1 {
    if (header.meta_offset != HEADER_SIZE) return error.BadLayout;
    if (header.meta_len > MAX_METADATA_BYTES_V1)
        return error.MetadataTooLarge;
    if (header.num_pages > MAX_PAGE_COUNT_V1)
        return error.IndexTooLarge;
    const meta_end = std.math.add(
        u64,
        header.meta_offset,
        header.meta_len,
    ) catch return error.LayoutOverflow;
    if (header.page_index_offset != meta_end) return error.BadLayout;
    const index_bytes = std.math.mul(
        u64,
        header.num_pages,
        PAGE_ENTRY_SIZE,
    ) catch return error.LayoutOverflow;
    const index_end = std.math.add(
        u64,
        header.page_index_offset,
        index_bytes,
    ) catch return error.LayoutOverflow;
    if (header.page_data_offset != index_end) return error.BadLayout;
    if (meta_end > file_size) return error.TruncatedMeta;
    if (index_end > file_size) return error.TruncatedIndex;
    return .{
        .meta_end = meta_end,
        .index_bytes = index_bytes,
        .index_end = index_end,
    };
}

fn validatePagesV1(
    pages: []const PageEntry,
    page_data_offset: u64,
    file_size: u64,
) !void {
    var expected_offset = page_data_offset;
    for (pages, 0..) |page, index| {
        if (page.page_id != @as(u64, @intCast(index)))
            return error.BadPageId;
        if (page.row_end <= page.row_start)
            return error.BadRowRange;
        if (page.data_len == 0)
            return error.EmptyPage;
        try validatePageGeometryV1(page);
        if (page.data_offset != expected_offset)
            return error.NonContiguousPayload;
        expected_offset = std.math.add(
            u64,
            page.data_offset,
            page.data_len,
        ) catch return error.LayoutOverflow;
        if (expected_offset > file_size)
            return error.TruncatedPage;
    }
    if (expected_offset != file_size)
        return error.TrailingBytes;
}

fn validatePageGeometryV1(page: PageEntry) !void {
    const element_count = page.row_end - page.row_start;
    const expected_len: u64 = switch (page.precision) {
        .fp32 => raw: {
            if (page.quant_group != 0) return error.BadQuantGroup;
            break :raw std.math.mul(
                u64,
                element_count,
                @sizeOf(f32),
            ) catch return error.LayoutOverflow;
        },
        .fp16, .bf16 => raw: {
            if (page.quant_group != 0) return error.BadQuantGroup;
            break :raw std.math.mul(
                u64,
                element_count,
                @sizeOf(u16),
            ) catch return error.LayoutOverflow;
        },
        .int8, .int4 => quantized: {
            if (page.quant_group == 0) return error.BadQuantGroup;
            // V1 quantization materializes one bounded F32 logical window.
            if (element_count > PAGE_SIZE_BYTES / @sizeOf(f32))
                return error.PageGeometryTooLarge;
            const group_count =
                element_count / page.quant_group +
                @intFromBool(element_count % page.quant_group != 0);
            const scale_bytes = std.math.mul(
                u64,
                group_count,
                @sizeOf(f32),
            ) catch return error.LayoutOverflow;
            const packed_bytes = if (page.precision == .int8)
                element_count
            else
                element_count / 2 +
                    @intFromBool(element_count % 2 != 0);
            const body_bytes = std.math.add(
                u64,
                scale_bytes,
                packed_bytes,
            ) catch return error.LayoutOverflow;
            break :quantized std.math.add(
                u64,
                qio.SUB_HEADER_SIZE,
                body_bytes,
            ) catch return error.LayoutOverflow;
        },
        .int2, .tri1p58 => return error.UnsupportedPrecision,
    };
    if (expected_len != page.data_len)
        return error.BadPageGeometry;
    if (page.precision == .fp32 or
        page.precision == .fp16 or
        page.precision == .bf16)
    {
        if (expected_len > PAGE_SIZE_BYTES)
            return error.PageGeometryTooLarge;
    }
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn validatePayloadSchemaV1(
    file: std.fs.File,
    page: PageEntry,
) !void {
    switch (page.precision) {
        .fp32, .fp16, .bf16 => return,
        .int8, .int4 => {},
        .int2, .tri1p58 => return error.UnsupportedPrecision,
    }
    var encoded: [qio.SUB_HEADER_SIZE]u8 = undefined;
    if (try file.preadAll(&encoded, page.data_offset) != encoded.len)
        return error.TruncatedPage;
    if (!allZero(encoded[13..16]))
        return error.BadQuantPayload;
    const header = qio.readQuantHeader(&encoded) catch
        return error.BadQuantPayload;
    const element_count = page.row_end - page.row_start;
    if (header.num_elements != element_count or
        header.group_size != page.quant_group)
        return error.BadQuantPayload;
    const expected_precision: core.quant.QuantPrecision =
        if (page.precision == .int8) .int8 else .int4;
    if (header.precision != expected_precision)
        return error.BadQuantPayload;
}

/// Strict reader for the portable `.glacier` container.
pub const FileReader = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    header: Header,
    pages: []PageEntry,
    meta_bytes: []u8,
    container_bytes: u64,
    ownership: FileOwnership,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !FileReader {
        const file = try std.fs.cwd().openFile(path, .{});
        return openOwnedFile(allocator, file);
    }

    /// Admit an already-open file and take ownership of its handle on both
    /// success and failure.
    pub fn openOwnedFile(
        allocator: std.mem.Allocator,
        file: std.fs.File,
    ) !FileReader {
        return openFile(allocator, file, .owned);
    }

    /// Admit an already-open file without taking ownership. The caller must
    /// keep the handle open for the reader's entire lifetime and close it
    /// after the reader.
    pub fn openBorrowedFile(
        allocator: std.mem.Allocator,
        file: std.fs.File,
    ) !FileReader {
        return openFile(allocator, file, .borrowed);
    }

    fn openFile(
        allocator: std.mem.Allocator,
        file: std.fs.File,
        ownership: FileOwnership,
    ) !FileReader {
        errdefer if (ownership == .owned) file.close();
        const stat = try file.stat();
        if (stat.size < HEADER_SIZE) return error.TruncatedHeader;
        const header = blk: {
            var hbuf: [HEADER_SIZE]u8 = undefined;
            const n = try file.preadAll(&hbuf, 0);
            if (n != HEADER_SIZE) return error.TruncatedHeader;
            var fbs = std.io.fixedBufferStream(&hbuf);
            break :blk try Header.readFrom(fbs.reader());
        };
        _ = try validateHeaderLayoutV1(header, stat.size);

        // Metadata blob.
        const meta_len = std.math.cast(usize, header.meta_len) orelse
            return error.MetadataTooLarge;
        const meta_bytes = try allocator.alloc(u8, meta_len);
        errdefer allocator.free(meta_bytes);
        const meta_n = try file.preadAll(meta_bytes, header.meta_offset);
        if (meta_n != meta_bytes.len) return error.TruncatedMeta;
        const parsed_metadata = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            meta_bytes,
            .{},
        ) catch return error.BadMetadata;
        defer parsed_metadata.deinit();
        if (parsed_metadata.value != .object)
            return error.BadMetadata;

        // Page index.
        const num_pages = std.math.cast(usize, header.num_pages) orelse
            return error.IndexTooLarge;
        const pages = try allocator.alloc(PageEntry, num_pages);
        errdefer allocator.free(pages);
        for (pages, 0..) |*p, idx| {
            var entry_bytes: [PAGE_ENTRY_SIZE]u8 = undefined;
            const entry_offset = std.math.add(
                u64,
                header.page_index_offset,
                std.math.mul(
                    u64,
                    @intCast(idx),
                    PAGE_ENTRY_SIZE,
                ) catch return error.LayoutOverflow,
            ) catch return error.LayoutOverflow;
            if (try file.preadAll(&entry_bytes, entry_offset) !=
                entry_bytes.len)
                return error.TruncatedIndex;
            var fbs = std.io.fixedBufferStream(&entry_bytes);
            p.* = try PageEntry.readFrom(fbs.reader());
        }
        try validatePagesV1(
            pages,
            header.page_data_offset,
            stat.size,
        );

        return .{
            .allocator = allocator,
            .file = file,
            .header = header,
            .pages = pages,
            .meta_bytes = meta_bytes,
            .container_bytes = stat.size,
            .ownership = ownership,
        };
    }

    pub fn close(self: *FileReader) void {
        if (self.ownership == .owned) self.file.close();
        self.allocator.free(self.pages);
        self.allocator.free(self.meta_bytes);
        self.* = undefined;
    }

    /// Read a page's payload into caller-provided buffer. Verifies CRC32.
    pub fn readPage(self: *FileReader, page: PageEntry, dst: []u8) !void {
        if (dst.len < page.data_len) return error.BufferTooSmall;
        const got = try self.file.preadAll(dst[0..@intCast(page.data_len)], page.data_offset);
        if (got != page.data_len) return error.TruncatedPage;
        const got_crc = accelerated_crc32.hash(dst[0..@intCast(page.data_len)]);
        if (got_crc != page.crc32) return error.CrcMismatch;
    }

    /// Validate every admitted page CRC with bounded stack storage.
    pub fn validateAllPageCrcs(self: *const FileReader) !void {
        var buffer: [STREAM_BUFFER_SIZE]u8 = undefined;
        return self.validateAllPageCrcsWithBufferV1(&buffer);
    }

    /// Validate every admitted page CRC using caller-provided bounded storage.
    pub fn validateAllPageCrcsWithBufferV1(
        self: *const FileReader,
        buffer: []u8,
    ) !void {
        if (buffer.len == 0) return error.EmptyStreamBuffer;
        for (self.pages) |page| {
            try validatePayloadSchemaV1(self.file, page);
            var crc = std.hash.Crc32.init();
            var offset = page.data_offset;
            var remaining = page.data_len;
            while (remaining != 0) {
                const chunk_len: usize = @intCast(@min(
                    remaining,
                    @as(u64, @intCast(buffer.len)),
                ));
                const chunk = buffer[0..chunk_len];
                if (try self.file.preadAll(chunk, offset) != chunk.len)
                    return error.TruncatedPage;
                crc.update(chunk);
                offset = std.math.add(
                    u64,
                    offset,
                    chunk.len,
                ) catch return error.LayoutOverflow;
                remaining -= chunk.len;
            }
            if (crc.final() != page.crc32)
                return error.CrcMismatch;
        }
    }

    /// Hash every physical byte of this admitted container with bounded stack
    /// storage. This is an exact physical identity, not a semantic model ID.
    pub fn containerIdentityV1(
        self: *const FileReader,
    ) !ContainerIdentityV1 {
        var buffer: [STREAM_BUFFER_SIZE]u8 = undefined;
        return self.containerIdentityWithBufferV1(&buffer);
    }

    /// Hash every physical byte using caller-provided bounded storage.
    pub fn containerIdentityWithBufferV1(
        self: *const FileReader,
        buffer: []u8,
    ) !ContainerIdentityV1 {
        if (buffer.len == 0) return error.EmptyStreamBuffer;
        var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
        var offset: u64 = 0;
        while (offset < self.container_bytes) {
            const remaining = self.container_bytes - offset;
            const chunk_len: usize = @intCast(@min(
                remaining,
                @as(u64, @intCast(buffer.len)),
            ));
            const chunk = buffer[0..chunk_len];
            if (try self.file.preadAll(chunk, offset) != chunk.len)
                return error.TruncatedContainer;
            sha256.update(chunk);
            offset = std.math.add(
                u64,
                offset,
                chunk.len,
            ) catch return error.LayoutOverflow;
        }
        var digest: [32]u8 = undefined;
        sha256.final(&digest);
        return .{
            .container_bytes = self.container_bytes,
            .container_sha256 = digest,
        };
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
        switch (page.precision) {
            .fp32, .fp16, .bf16 => return decodeRawPageV1(
                DstDType,
                self.allocator,
                raw,
                page.precision,
                page.row_end - page.row_start,
            ),
            .int8, .int4 => {
                try validatePayloadSchemaV1(self.file, page);
                return try qio.decodePage(DstDType, self.allocator, raw);
            },
            .int2, .tri1p58 => return error.UnsupportedPrecision,
        }
    }
};

fn decodeRawPageV1(
    comptime DstDType: type,
    allocator: std.mem.Allocator,
    raw: []const u8,
    precision: StoredPrecision,
    element_count_u64: u64,
) ![]DstDType {
    if (comptime DstDType != f16 and
        DstDType != f32 and
        DstDType != f64)
    {
        return error.UnsupportedDestinationType;
    }
    const source_element_bytes: u64 = switch (precision) {
        .fp32 => @sizeOf(f32),
        .fp16, .bf16 => @sizeOf(u16),
        .int8, .int4, .int2, .tri1p58 => return error.UnsupportedPrecision,
    };
    const expected_bytes = std.math.mul(
        u64,
        element_count_u64,
        source_element_bytes,
    ) catch return error.SizeMismatch;
    if (expected_bytes != raw.len) return error.SizeMismatch;
    const element_count = std.math.cast(
        usize,
        element_count_u64,
    ) orelse return error.SizeMismatch;
    const out = try allocator.alloc(DstDType, element_count);
    errdefer allocator.free(out);
    const f16bits = core.f16bits;
    for (out, 0..) |*value, index| {
        const decoded: f32 = switch (precision) {
            .fp32 => @bitCast(std.mem.readInt(
                u32,
                raw[index * @sizeOf(f32) ..][0..@sizeOf(f32)],
                .little,
            )),
            .fp16 => f16bits.f16BitsToF32(std.mem.readInt(
                u16,
                raw[index * @sizeOf(u16) ..][0..@sizeOf(u16)],
                .little,
            )),
            .bf16 => @bitCast(
                @as(u32, std.mem.readInt(
                    u16,
                    raw[index * @sizeOf(u16) ..][0..@sizeOf(u16)],
                    .little,
                )) << 16,
            ),
            .int8, .int4, .int2, .tri1p58 => unreachable,
        };
        value.* = @floatCast(decoded);
    }
    return out;
}

// --------------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------------

const test_meta_v1 = "{\"format\":\"portable-test\"}";
const test_payloads_v1 = [_][]const u8{
    "abcdefgh",
    "ijklmnop",
};
const test_index_offset_v1: u64 = HEADER_SIZE + test_meta_v1.len;
const test_data_offset_v1: u64 =
    test_index_offset_v1 + PAGE_ENTRY_SIZE * test_payloads_v1.len;
const test_container_bytes_v1: u64 =
    test_data_offset_v1 + test_payloads_v1[0].len + test_payloads_v1[1].len;

fn writeTestContainerV1(file: std.fs.File) !void {
    try file.setEndPos(0);

    const header = Header{
        .meta_offset = HEADER_SIZE,
        .meta_len = test_meta_v1.len,
        .num_pages = test_payloads_v1.len,
        .page_index_offset = test_index_offset_v1,
        .page_data_offset = test_data_offset_v1,
    };
    var header_bytes: [HEADER_SIZE]u8 = undefined;
    var header_stream = std.io.fixedBufferStream(&header_bytes);
    try header.writeTo(header_stream.writer());
    try file.pwriteAll(&header_bytes, 0);
    try file.pwriteAll(test_meta_v1, HEADER_SIZE);

    var data_offset = test_data_offset_v1;
    for (test_payloads_v1, 0..) |payload, index| {
        const entry = PageEntry{
            .page_id = @intCast(index),
            .layer_idx = @intCast(index),
            .tensor_kind = if (index == 0) .embedding else .other,
            .row_start = @as(u64, @intCast(index)) * 4,
            .row_end = @as(u64, @intCast(index)) * 4 + 4,
            .precision = .fp16,
            .quant_group = 0,
            .crc32 = std.hash.Crc32.hash(payload),
            .data_offset = data_offset,
            .data_len = payload.len,
        };
        var entry_bytes: [PAGE_ENTRY_SIZE]u8 = undefined;
        var entry_stream = std.io.fixedBufferStream(&entry_bytes);
        try entry.writeTo(entry_stream.writer());
        try file.pwriteAll(
            &entry_bytes,
            test_index_offset_v1 + index * PAGE_ENTRY_SIZE,
        );
        try file.pwriteAll(payload, data_offset);
        data_offset += payload.len;
    }
    try file.setEndPos(test_container_bytes_v1);
}

fn writeTestU64V1(file: std.fs.File, offset: u64, value: u64) !void {
    var bytes: [@sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try file.pwriteAll(&bytes, offset);
}

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

test "portable page geometry rejects lying precision descriptors" {
    const raw = PageEntry{
        .page_id = 0,
        .layer_idx = 0,
        .tensor_kind = .other,
        .row_start = 0,
        .row_end = 4,
        .precision = .fp16,
        .quant_group = 0,
        .crc32 = 0,
        .data_offset = HEADER_SIZE,
        .data_len = 8,
    };
    try validatePageGeometryV1(raw);

    var mutated = raw;
    mutated.data_len = 7;
    try std.testing.expectError(
        error.BadPageGeometry,
        validatePageGeometryV1(mutated),
    );
    mutated = raw;
    mutated.quant_group = 4;
    try std.testing.expectError(
        error.BadQuantGroup,
        validatePageGeometryV1(mutated),
    );
    mutated = raw;
    mutated.precision = .int2;
    try std.testing.expectError(
        error.UnsupportedPrecision,
        validatePageGeometryV1(mutated),
    );
    mutated = raw;
    mutated.row_end =
        PAGE_SIZE_BYTES / @sizeOf(u16) + 1;
    mutated.data_len = mutated.row_end * @sizeOf(u16);
    try std.testing.expectError(
        error.PageGeometryTooLarge,
        validatePageGeometryV1(mutated),
    );
}

test "raw page decoding is numerical and little endian" {
    const fp32_bytes = [_]u8{
        0x00, 0x00, 0x80, 0x3f,
        0x00, 0x00, 0x20, 0xc0,
    };
    const fp32 = try decodeRawPageV1(
        f32,
        std.testing.allocator,
        &fp32_bytes,
        .fp32,
        2,
    );
    defer std.testing.allocator.free(fp32);
    try std.testing.expectEqualSlices(
        f32,
        &.{ 1.0, -2.5 },
        fp32,
    );

    const fp16_bytes = [_]u8{
        0x00, 0x3c,
        0x00, 0xc1,
    };
    const fp16 = try decodeRawPageV1(
        f32,
        std.testing.allocator,
        &fp16_bytes,
        .fp16,
        2,
    );
    defer std.testing.allocator.free(fp16);
    try std.testing.expectEqualSlices(
        f32,
        &.{ 1.0, -2.5 },
        fp16,
    );

    const bf16_bytes = [_]u8{
        0x80, 0x3f,
        0x20, 0xc0,
    };
    const bf16 = try decodeRawPageV1(
        f32,
        std.testing.allocator,
        &bf16_bytes,
        .bf16,
        2,
    );
    defer std.testing.allocator.free(bf16);
    try std.testing.expectEqualSlices(
        f32,
        &.{ 1.0, -2.5 },
        bf16,
    );

    try std.testing.expectError(
        error.SizeMismatch,
        decodeRawPageV1(
            f32,
            std.testing.allocator,
            fp16_bytes[0..3],
            .fp16,
            2,
        ),
    );
}

test "portable quant payload schema binds entry geometry" {
    var source: [64]f32 = undefined;
    for (&source, 0..) |*value, index|
        value.* = @floatFromInt(index);
    const payload = try qio.encodePage(
        f32,
        std.testing.allocator,
        &source,
        .int4,
        32,
    );
    defer std.testing.allocator.free(payload);

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(
        "quant.payload",
        .{ .read = true },
    );
    defer file.close();
    try file.writeAll(payload);
    const page = PageEntry{
        .page_id = 0,
        .layer_idx = 0,
        .tensor_kind = .other,
        .row_start = 0,
        .row_end = source.len,
        .precision = .int4,
        .quant_group = 32,
        .crc32 = accelerated_crc32.hash(payload),
        .data_offset = 0,
        .data_len = payload.len,
    };
    try validatePageGeometryV1(page);
    try validatePayloadSchemaV1(file, page);

    try file.pwriteAll(&[_]u8{1}, 13);
    try std.testing.expectError(
        error.BadQuantPayload,
        validatePayloadSchemaV1(file, page),
    );
}

test "portable glacier strict admission owns and borrows exact files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try tmp.dir.createFile("portable.glacier", .{ .read = true });
        defer file.close();
        try writeTestContainerV1(file);
    }
    const path = try tmp.dir.realpathAlloc(
        std.testing.allocator,
        "portable.glacier",
    );
    defer std.testing.allocator.free(path);

    var path_reader = try FileReader.open(std.testing.allocator, path);
    defer path_reader.close();
    try std.testing.expectEqual(
        test_container_bytes_v1,
        path_reader.container_bytes,
    );
    try std.testing.expectEqual(@as(usize, 2), path_reader.pages.len);
    try std.testing.expectEqual(TensorKind.other, path_reader.pages[1].tensor_kind);

    var tiny_buffer: [3]u8 = undefined;
    try path_reader.validateAllPageCrcsWithBufferV1(&tiny_buffer);
    try path_reader.validateAllPageCrcs();
    const identity = try path_reader.containerIdentityWithBufferV1(&tiny_buffer);
    const default_identity = try path_reader.containerIdentityV1();
    try std.testing.expectEqual(test_container_bytes_v1, identity.container_bytes);
    try std.testing.expectEqualSlices(
        u8,
        &identity.container_sha256,
        &default_identity.container_sha256,
    );

    var physical_bytes: [test_container_bytes_v1]u8 = undefined;
    const identity_file = try tmp.dir.openFile("portable.glacier", .{});
    defer identity_file.close();
    try std.testing.expectEqual(
        physical_bytes.len,
        try identity_file.preadAll(&physical_bytes, 0),
    );
    var expected_sha256: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        &physical_bytes,
        &expected_sha256,
        .{},
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected_sha256,
        &identity.container_sha256,
    );

    try std.testing.expectError(
        error.EmptyStreamBuffer,
        path_reader.validateAllPageCrcsWithBufferV1(&.{}),
    );
    try std.testing.expectError(
        error.EmptyStreamBuffer,
        path_reader.containerIdentityWithBufferV1(&.{}),
    );

    const borrowed_file = try tmp.dir.openFile(
        "portable.glacier",
        .{ .mode = .read_write },
    );
    defer borrowed_file.close();
    try borrowed_file.seekTo(7);
    var borrowed = try FileReader.openBorrowedFile(
        std.testing.allocator,
        borrowed_file,
    );
    try std.testing.expectEqual(@as(u64, 7), try borrowed_file.getPos());
    borrowed.close();
    var magic: [MAGIC.len]u8 = undefined;
    try std.testing.expectEqual(
        magic.len,
        try borrowed_file.preadAll(&magic, 0),
    );
    try std.testing.expectEqualSlices(u8, &MAGIC, &magic);

    const owned_file = try tmp.dir.openFile("portable.glacier", .{});
    var owned = try FileReader.openOwnedFile(
        std.testing.allocator,
        owned_file,
    );
    owned.close();

    const original_identity = try path_reader.containerIdentityV1();
    try borrowed_file.pwriteAll(&[_]u8{'X'}, test_data_offset_v1);
    try std.testing.expectError(
        error.CrcMismatch,
        path_reader.validateAllPageCrcs(),
    );
    const changed_identity = try path_reader.containerIdentityV1();
    try std.testing.expect(!std.mem.eql(
        u8,
        &original_identity.container_sha256,
        &changed_identity.container_sha256,
    ));
}

test "portable glacier header and entry reserved domains are strict" {
    const header = Header{
        .meta_offset = HEADER_SIZE,
        .meta_len = 0,
        .num_pages = 0,
        .page_index_offset = HEADER_SIZE,
        .page_data_offset = HEADER_SIZE,
    };
    var header_bytes: [HEADER_SIZE]u8 = undefined;
    var header_stream = std.io.fixedBufferStream(&header_bytes);
    try header.writeTo(header_stream.writer());

    var mutated_header = header_bytes;
    mutated_header[4] = VERSION + 1;
    var read_stream = std.io.fixedBufferStream(&mutated_header);
    try std.testing.expectError(
        error.BadVersion,
        Header.readFrom(read_stream.reader()),
    );

    mutated_header = header_bytes;
    mutated_header[6] = 1;
    read_stream = std.io.fixedBufferStream(&mutated_header);
    try std.testing.expectError(
        error.BadHeaderSize,
        Header.readFrom(read_stream.reader()),
    );

    mutated_header = header_bytes;
    mutated_header[48] = PAGE_SIZE_LOG2 + 1;
    read_stream = std.io.fixedBufferStream(&mutated_header);
    try std.testing.expectError(
        error.BadPageSize,
        Header.readFrom(read_stream.reader()),
    );

    mutated_header = header_bytes;
    mutated_header[52] = 1;
    read_stream = std.io.fixedBufferStream(&mutated_header);
    try std.testing.expectError(
        error.BadReservedField,
        Header.readFrom(read_stream.reader()),
    );

    mutated_header = header_bytes;
    mutated_header[HEADER_SIZE - 1] = 1;
    read_stream = std.io.fixedBufferStream(&mutated_header);
    try std.testing.expectError(
        error.BadReservedField,
        Header.readFrom(read_stream.reader()),
    );

    const entry = PageEntry{
        .page_id = 0,
        .layer_idx = 0,
        .tensor_kind = .other,
        .row_start = 0,
        .row_end = 1,
        .precision = .fp16,
        .quant_group = 0,
        .crc32 = 0,
        .data_offset = HEADER_SIZE,
        .data_len = 1,
    };
    var entry_bytes: [PAGE_ENTRY_SIZE]u8 = undefined;
    var entry_stream = std.io.fixedBufferStream(&entry_bytes);
    try entry.writeTo(entry_stream.writer());
    var mutated_entry = entry_bytes;

    std.mem.writeInt(u32, mutated_entry[12..16], 16, .little);
    var entry_read_stream = std.io.fixedBufferStream(&mutated_entry);
    try std.testing.expectError(
        error.BadTensorKind,
        PageEntry.readFrom(entry_read_stream.reader()),
    );

    mutated_entry = entry_bytes;
    mutated_entry[32] = std.math.maxInt(u8);
    entry_read_stream = std.io.fixedBufferStream(&mutated_entry);
    try std.testing.expectError(
        error.BadPrecision,
        PageEntry.readFrom(entry_read_stream.reader()),
    );

    inline for (.{ 34, 56, 60 }) |reserved_offset| {
        mutated_entry = entry_bytes;
        mutated_entry[reserved_offset] = 1;
        entry_read_stream = std.io.fixedBufferStream(&mutated_entry);
        try std.testing.expectError(
            error.BadReservedField,
            PageEntry.readFrom(entry_read_stream.reader()),
        );
    }
}

test "portable glacier exact layout rejects overflow gaps and trailing bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(
        "layout.glacier",
        .{ .read = true },
    );
    defer file.close();
    const path = try tmp.dir.realpathAlloc(
        std.testing.allocator,
        "layout.glacier",
    );
    defer std.testing.allocator.free(path);

    try writeTestContainerV1(file);
    try file.pwriteAll("!", HEADER_SIZE);
    try std.testing.expectError(
        error.BadMetadata,
        FileReader.open(std.testing.allocator, path),
    );

    try writeTestContainerV1(file);
    try writeTestU64V1(file, 8, HEADER_SIZE + 1);
    try std.testing.expectError(
        error.BadLayout,
        FileReader.open(std.testing.allocator, path),
    );

    try writeTestContainerV1(file);
    try writeTestU64V1(file, 24, std.math.maxInt(u64));
    try std.testing.expectError(
        error.IndexTooLarge,
        FileReader.open(std.testing.allocator, path),
    );

    try writeTestContainerV1(file);
    try writeTestU64V1(file, test_index_offset_v1, 1);
    try std.testing.expectError(
        error.BadPageId,
        FileReader.open(std.testing.allocator, path),
    );

    try writeTestContainerV1(file);
    try writeTestU64V1(file, test_index_offset_v1 + 24, 0);
    try std.testing.expectError(
        error.BadRowRange,
        FileReader.open(std.testing.allocator, path),
    );

    try writeTestContainerV1(file);
    try writeTestU64V1(file, test_index_offset_v1 + 44, 0);
    try std.testing.expectError(
        error.EmptyPage,
        FileReader.open(std.testing.allocator, path),
    );

    try writeTestContainerV1(file);
    try writeTestU64V1(
        file,
        test_index_offset_v1 + PAGE_ENTRY_SIZE + 36,
        test_data_offset_v1 + test_payloads_v1[0].len + 1,
    );
    try std.testing.expectError(
        error.NonContiguousPayload,
        FileReader.open(std.testing.allocator, path),
    );

    try writeTestContainerV1(file);
    try file.pwriteAll(&[_]u8{0}, test_container_bytes_v1);
    try std.testing.expectError(
        error.TrailingBytes,
        FileReader.open(std.testing.allocator, path),
    );

    try writeTestContainerV1(file);
    try file.setEndPos(test_container_bytes_v1 - 1);
    try std.testing.expectError(
        error.TruncatedPage,
        FileReader.open(std.testing.allocator, path),
    );
}

test "portable glacier bounds metadata and page-index admission" {
    const base = Header{
        .meta_offset = HEADER_SIZE,
        .meta_len = 0,
        .num_pages = 0,
        .page_index_offset = HEADER_SIZE,
        .page_data_offset = HEADER_SIZE,
    };
    var oversized_metadata = base;
    oversized_metadata.meta_len = MAX_METADATA_BYTES_V1 + 1;
    oversized_metadata.page_index_offset =
        HEADER_SIZE + oversized_metadata.meta_len;
    oversized_metadata.page_data_offset =
        oversized_metadata.page_index_offset;
    try std.testing.expectError(
        error.MetadataTooLarge,
        validateHeaderLayoutV1(
            oversized_metadata,
            std.math.maxInt(u64),
        ),
    );

    var oversized_index = base;
    oversized_index.num_pages = MAX_PAGE_COUNT_V1 + 1;
    oversized_index.page_data_offset = std.math.add(
        u64,
        HEADER_SIZE,
        std.math.mul(
            u64,
            oversized_index.num_pages,
            PAGE_ENTRY_SIZE,
        ) catch unreachable,
    ) catch unreachable;
    try std.testing.expectError(
        error.IndexTooLarge,
        validateHeaderLayoutV1(
            oversized_index,
            std.math.maxInt(u64),
        ),
    );
}
