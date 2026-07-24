//! Native, mmap-friendly runtime image codec.
//!
//! A `.glrt` image is a derived cache, not a portable model container.  It
//! stores the exact byte streams consumed by Glacier's runtime so a process
//! can map weights read-only instead of concatenating, repacking, and
//! converting scale grids on every start.
//!
//! All integer fields are little-endian.  GLRT v1 is an explicitly read-only
//! compatibility ABI with 128-byte records.  Writers emit GLRT v2, whose
//! 160-byte records add execution roles, PairNibble layout metadata, and a
//! SHA-256 digest over the canonical descriptor plus payload.  Both versions
//! retain a 512-byte header and 64-byte-aligned streams.  Never write Zig
//! structs directly; the explicit codec below keeps compiler padding and enum
//! representation out of the format.

const std = @import("std");
const builtin = @import("builtin");
const fmt = @import("format.zig");
const accelerated_crc32 = @import("../crc32.zig");

pub const MAGIC: [4]u8 = .{ 'G', 'L', 'R', 'T' };
pub const Version = enum(u16) {
    v1 = 1,
    v2 = 2,
};

/// Current writer version. Readers also accept the explicit read-only v1 ABI.
pub const VERSION: u16 = @intFromEnum(Version.v2);
pub const HEADER_SIZE: usize = 512;
pub const V1_RECORD_SIZE: usize = 128;
pub const RECORD_SIZE: usize = 160;
pub const DATA_ALIGNMENT: u16 = 64;
/// Layer index reserved for embedding, final_norm, and lm_head records.
pub const GLOBAL_LAYER: u32 = std.math.maxInt(u32);

/// AArch64 prepared images contain the rows4/K16 + FP16 scale representation
/// consumed by the native packed kernels. Preserve this value for GLRT v1
/// AArch64 artifacts; it is SHA-256 of
/// "GLRT v1 header512 record128 rows4-k16 f16-v1".
const ABI_FINGERPRINT_V1_AARCH64: [32]u8 = .{
    0xdc, 0x5f, 0xe7, 0x78, 0xa2, 0x81, 0x50, 0x23,
    0x5c, 0x6f, 0x11, 0xc5, 0x3b, 0xbf, 0x87, 0x6e,
    0x13, 0x0d, 0xde, 0x08, 0x04, 0xc3, 0xb7, 0xa4,
    0x92, 0xf4, 0xde, 0x7e, 0x05, 0x9b, 0xc7, 0xad,
};

/// Non-AArch64 preparation retains row-major packed nibbles and FP32 scales.
/// It is SHA-256 of
/// "GLRT v1 header512 record128 row-major-f32-v1".
const ABI_FINGERPRINT_V1_PORTABLE: [32]u8 = .{
    0x0c, 0x1f, 0x18, 0x5c, 0xef, 0xf5, 0xe9, 0xd3,
    0x66, 0xa9, 0x20, 0xc8, 0xb0, 0x04, 0x6f, 0x15,
    0x43, 0x29, 0x0f, 0x85, 0x96, 0x5f, 0xbd, 0x7c,
    0xb1, 0x3f, 0x21, 0xfe, 0x2e, 0xec, 0x42, 0xb6,
};

/// GLRT v2 AArch64 execution image. It is SHA-256 of
/// "GLRT v2 header512 record160 roles pair-nibble descriptor-payload-sha256 rows4-k16 f16-v2".
const ABI_FINGERPRINT_V2_AARCH64: [32]u8 = .{
    0xd0, 0xd7, 0xdf, 0x06, 0x35, 0x0a, 0xf6, 0xb2,
    0xd4, 0x8e, 0x28, 0x2f, 0x65, 0xff, 0x87, 0x3a,
    0x3c, 0xf9, 0x5b, 0xd6, 0x39, 0x7b, 0x1d, 0x2d,
    0x26, 0xcc, 0x6e, 0x67, 0x93, 0x04, 0xe0, 0x6f,
};

/// GLRT v2 portable execution image. It is SHA-256 of
/// "GLRT v2 header512 record160 roles pair-nibble descriptor-payload-sha256 row-major-f32-v2".
const ABI_FINGERPRINT_V2_PORTABLE: [32]u8 = .{
    0x8f, 0x29, 0x14, 0x72, 0xbe, 0x36, 0xfa, 0xb2,
    0xd8, 0xe3, 0x2b, 0xfb, 0xb8, 0x76, 0x71, 0xeb,
    0xbb, 0x18, 0xa9, 0x82, 0x03, 0x6a, 0x2d, 0x17,
    0xdc, 0x06, 0xcb, 0xe2, 0x90, 0x7e, 0xc8, 0x90,
};

pub fn abiFingerprintForVersion(
    arch: std.Target.Cpu.Arch,
    version: Version,
) [32]u8 {
    return switch (version) {
        .v1 => if (arch == .aarch64)
            ABI_FINGERPRINT_V1_AARCH64
        else
            ABI_FINGERPRINT_V1_PORTABLE,
        .v2 => if (arch == .aarch64)
            ABI_FINGERPRINT_V2_AARCH64
        else
            ABI_FINGERPRINT_V2_PORTABLE,
    };
}

/// Current-version helper retained for callers that do not need legacy ABI
/// introspection.
pub fn abiFingerprintFor(arch: std.Target.Cpu.Arch) [32]u8 {
    return abiFingerprintForVersion(arch, .v2);
}

/// Runtime images fail closed when their execution layout does not match the
/// architecture policy compiled into this binary.
pub const ABI_FINGERPRINT: [32]u8 = abiFingerprintFor(builtin.cpu.arch);
pub const ABI_FINGERPRINT_V1: [32]u8 = abiFingerprintForVersion(builtin.cpu.arch, .v1);

const HEADER_CRC_OFFSET: usize = 156;
const V2_ROLE_OFFSET: usize = 120;
const V2_PAIR_LAYOUT_OFFSET: usize = 122;
const V2_DIGEST_OFFSET: usize = 128;

fn recordSizeFor(version: Version) usize {
    return switch (version) {
        .v1 => V1_RECORD_SIZE,
        .v2 => RECORD_SIZE,
    };
}

pub const Encoding = enum(u16) {
    raw_f32 = 0,
    int4 = 1,
    pair_nibble = 2,
};

/// Values 0 and 1 intentionally match `int4_weights.PackedLayout`.
pub const PackedLayout = enum(u16) {
    row_major = 0,
    rows4_k16 = 1,
    none = 0xffff,
};

/// Execution purpose is independent of the source tensor kind. In v1 every
/// record decodes as `tensor`; v2 can add an execution artifact without
/// inventing a synthetic `TensorKind`.
pub const Role = enum(u16) {
    tensor = 0,
    mlp_gate_up_pair = 1,
};

pub const PairNibbleLayout = enum(u16) {
    rows4_k16 = 0,
    none = 0xffff,
};

pub const Stream = enum(u8) {
    packed_weights,
    scales_f32,
    scales_f16,
    scales_f16_rows4,
    raw,
};

const all_streams = [_]Stream{
    .packed_weights,
    .scales_f32,
    .scales_f16,
    .scales_f16_rows4,
    .raw,
};

pub const ConfigSnapshot = struct {
    dim: u32,
    hidden_dim: u32,
    layers: u32,
    vocab: u32,
    heads: u32,
    head_dim: u32,
    kv_heads: u32,
    rms_eps: f32,
    rope_theta: f32,
    tie_embeddings: bool,

    fn validate(self: ConfigSnapshot) !void {
        if (self.dim == 0 or self.hidden_dim == 0 or self.layers == 0 or
            self.vocab == 0 or self.heads == 0 or self.head_dim == 0 or
            self.kv_heads == 0)
        {
            return error.BadConfig;
        }
        if (!std.math.isFinite(self.rms_eps) or self.rms_eps <= 0 or
            !std.math.isFinite(self.rope_theta) or self.rope_theta <= 0)
        {
            return error.BadConfig;
        }
    }
};

pub const Header = struct {
    version: Version = .v2,
    flags: u32 = 0,
    record_count: u64,
    index_offset: u64 = HEADER_SIZE,
    data_offset: u64,
    file_size: u64,
    source_fingerprint: [32]u8,
    abi_fingerprint: [32]u8 = ABI_FINGERPRINT,
    config: ConfigSnapshot,
    index_crc32: u32,
    header_crc32: u32,

    fn encode(self: Header) [HEADER_SIZE]u8 {
        var out: [HEADER_SIZE]u8 = @splat(0);
        @memcpy(out[0..4], &MAGIC);
        putInt(u16, out[4..6], @intFromEnum(self.version));
        putInt(u16, out[6..8], HEADER_SIZE);
        putInt(u16, out[8..10], @intCast(recordSizeFor(self.version)));
        putInt(u16, out[10..12], DATA_ALIGNMENT);
        putInt(u32, out[12..16], self.flags);
        putInt(u64, out[16..24], self.record_count);
        putInt(u64, out[24..32], self.index_offset);
        putInt(u64, out[32..40], self.data_offset);
        putInt(u64, out[40..48], self.file_size);
        @memcpy(out[48..80], &self.source_fingerprint);
        @memcpy(out[80..112], &self.abi_fingerprint);
        putInt(u32, out[112..116], self.config.dim);
        putInt(u32, out[116..120], self.config.hidden_dim);
        putInt(u32, out[120..124], self.config.layers);
        putInt(u32, out[124..128], self.config.vocab);
        putInt(u32, out[128..132], self.config.heads);
        putInt(u32, out[132..136], self.config.head_dim);
        putInt(u32, out[136..140], self.config.kv_heads);
        out[140] = @intFromBool(self.config.tie_embeddings);
        putInt(u32, out[144..148], @bitCast(self.config.rms_eps));
        putInt(u32, out[148..152], @bitCast(self.config.rope_theta));
        putInt(u32, out[152..156], self.index_crc32);
        putInt(u32, out[HEADER_CRC_OFFSET..][0..4], self.header_crc32);
        return out;
    }

    fn decode(bytes: []const u8) !Header {
        if (bytes.len < HEADER_SIZE) return error.TruncatedHeader;
        if (!std.mem.eql(u8, bytes[0..4], &MAGIC)) return error.BadMagic;
        const version = std.meta.intToEnum(Version, getInt(u16, bytes[4..6])) catch
            return error.BadVersion;
        if (getInt(u16, bytes[6..8]) != HEADER_SIZE) return error.BadHeaderSize;
        if (getInt(u16, bytes[8..10]) != recordSizeFor(version))
            return error.BadRecordSize;
        if (getInt(u16, bytes[10..12]) != DATA_ALIGNMENT) return error.BadAlignment;
        if (bytes[140] > 1) return error.BadConfig;
        if (!allZero(bytes[141..144]) or !allZero(bytes[160..HEADER_SIZE]))
            return error.BadReservedField;

        var source_fingerprint: [32]u8 = undefined;
        var abi_fingerprint: [32]u8 = undefined;
        @memcpy(&source_fingerprint, bytes[48..80]);
        @memcpy(&abi_fingerprint, bytes[80..112]);
        const out: Header = .{
            .version = version,
            .flags = getInt(u32, bytes[12..16]),
            .record_count = getInt(u64, bytes[16..24]),
            .index_offset = getInt(u64, bytes[24..32]),
            .data_offset = getInt(u64, bytes[32..40]),
            .file_size = getInt(u64, bytes[40..48]),
            .source_fingerprint = source_fingerprint,
            .abi_fingerprint = abi_fingerprint,
            .config = .{
                .dim = getInt(u32, bytes[112..116]),
                .hidden_dim = getInt(u32, bytes[116..120]),
                .layers = getInt(u32, bytes[120..124]),
                .vocab = getInt(u32, bytes[124..128]),
                .heads = getInt(u32, bytes[128..132]),
                .head_dim = getInt(u32, bytes[132..136]),
                .kv_heads = getInt(u32, bytes[136..140]),
                .tie_embeddings = bytes[140] != 0,
                .rms_eps = @bitCast(getInt(u32, bytes[144..148])),
                .rope_theta = @bitCast(getInt(u32, bytes[148..152])),
            },
            .index_crc32 = getInt(u32, bytes[152..156]),
            .header_crc32 = getInt(u32, bytes[HEADER_CRC_OFFSET..][0..4]),
        };
        try out.config.validate();
        return out;
    }
};

pub const RecordKey = struct {
    layer_idx: u32,
    kind: fmt.TensorKind,

    pub fn eql(a: RecordKey, b: RecordKey) bool {
        return a.layer_idx == b.layer_idx and a.kind == b.kind;
    }
};

pub const SliceRange = struct {
    offset: u64 = 0,
    len: u64 = 0,
};

pub const Record = struct {
    key: RecordKey,
    role: Role = .tensor,
    encoding: Encoding,
    packed_layout: PackedLayout,
    pair_nibble_layout: PairNibbleLayout = .none,
    group_size: u32,
    out_f: u32,
    in_f: u32,
    flags: u32 = 0,
    num_elements: u64,
    packed_bytes: SliceRange = .{},
    scales_f32: SliceRange = .{},
    scales_f16: SliceRange = .{},
    scales_f16_rows4: SliceRange = .{},
    raw: SliceRange = .{},
    payload_crc32: u32,
    /// V2 hashes canonical descriptor bytes 0..128 followed by every payload
    /// stream in `all_streams` order. V1 records always expose all-zero bytes.
    payload_digest: [32]u8 = @splat(0),

    fn identityEql(a: Record, b: Record) bool {
        if (a.key.layer_idx != b.key.layer_idx or a.role != b.role) return false;
        return a.role != .tensor or a.key.kind == b.key.kind;
    }

    pub fn range(self: Record, stream: Stream) SliceRange {
        return switch (stream) {
            .packed_weights => self.packed_bytes,
            .scales_f32 => self.scales_f32,
            .scales_f16 => self.scales_f16,
            .scales_f16_rows4 => self.scales_f16_rows4,
            .raw => self.raw,
        };
    }

    fn setRange(self: *Record, stream: Stream, value: SliceRange) void {
        switch (stream) {
            .packed_weights => self.packed_bytes = value,
            .scales_f32 => self.scales_f32 = value,
            .scales_f16 => self.scales_f16 = value,
            .scales_f16_rows4 => self.scales_f16_rows4 = value,
            .raw => self.raw = value,
        }
    }

    fn encode(self: Record, version: Version) [RECORD_SIZE]u8 {
        var out: [RECORD_SIZE]u8 = @splat(0);
        putInt(u32, out[0..4], self.key.layer_idx);
        putInt(u32, out[4..8], @intFromEnum(self.key.kind));
        putInt(u16, out[8..10], @intFromEnum(self.encoding));
        putInt(u16, out[10..12], @intFromEnum(self.packed_layout));
        putInt(u32, out[12..16], self.group_size);
        putInt(u32, out[16..20], self.out_f);
        putInt(u32, out[20..24], self.in_f);
        putInt(u32, out[24..28], self.flags);
        putInt(u32, out[28..32], self.payload_crc32);
        putInt(u64, out[32..40], self.num_elements);
        encodeRange(out[40..56], self.packed_bytes);
        encodeRange(out[56..72], self.scales_f32);
        encodeRange(out[72..88], self.scales_f16);
        encodeRange(out[88..104], self.scales_f16_rows4);
        encodeRange(out[104..120], self.raw);
        if (version == .v2) {
            putInt(u16, out[V2_ROLE_OFFSET..][0..2], @intFromEnum(self.role));
            putInt(
                u16,
                out[V2_PAIR_LAYOUT_OFFSET..][0..2],
                @intFromEnum(self.pair_nibble_layout),
            );
            @memcpy(out[V2_DIGEST_OFFSET..RECORD_SIZE], &self.payload_digest);
        }
        return out;
    }

    fn decode(bytes: []const u8, version: Version) !Record {
        const record_size = recordSizeFor(version);
        if (bytes.len < record_size) return error.TruncatedIndex;
        switch (version) {
            .v1 => if (!allZero(bytes[120..V1_RECORD_SIZE]))
                return error.BadReservedField,
            .v2 => if (!allZero(bytes[124..V2_DIGEST_OFFSET]))
                return error.BadReservedField,
        }
        const kind = std.meta.intToEnum(fmt.TensorKind, getInt(u32, bytes[4..8])) catch
            return error.BadTensorKind;
        const encoding = std.meta.intToEnum(Encoding, getInt(u16, bytes[8..10])) catch
            return error.BadEncoding;
        const layout = std.meta.intToEnum(PackedLayout, getInt(u16, bytes[10..12])) catch
            return error.BadPackedLayout;
        const role: Role = if (version == .v1)
            .tensor
        else
            std.meta.intToEnum(Role, getInt(u16, bytes[V2_ROLE_OFFSET..][0..2])) catch
                return error.BadRole;
        const pair_nibble_layout: PairNibbleLayout = if (version == .v1)
            .none
        else
            std.meta.intToEnum(
                PairNibbleLayout,
                getInt(u16, bytes[V2_PAIR_LAYOUT_OFFSET..][0..2]),
            ) catch return error.BadPairNibbleLayout;
        var payload_digest: [32]u8 = @splat(0);
        if (version == .v2) {
            @memcpy(&payload_digest, bytes[V2_DIGEST_OFFSET..RECORD_SIZE]);
        }
        return .{
            .key = .{ .layer_idx = getInt(u32, bytes[0..4]), .kind = kind },
            .role = role,
            .encoding = encoding,
            .packed_layout = layout,
            .pair_nibble_layout = pair_nibble_layout,
            .group_size = getInt(u32, bytes[12..16]),
            .out_f = getInt(u32, bytes[16..20]),
            .in_f = getInt(u32, bytes[20..24]),
            .flags = getInt(u32, bytes[24..28]),
            .payload_crc32 = getInt(u32, bytes[28..32]),
            .num_elements = getInt(u64, bytes[32..40]),
            .packed_bytes = decodeRange(bytes[40..56]),
            .scales_f32 = decodeRange(bytes[56..72]),
            .scales_f16 = decodeRange(bytes[72..88]),
            .scales_f16_rows4 = decodeRange(bytes[88..104]),
            .raw = decodeRange(bytes[104..120]),
            .payload_digest = payload_digest,
        };
    }

    fn validateDescriptor(
        self: Record,
        version: Version,
        require_digest: bool,
    ) !void {
        if (self.flags != 0) return error.BadFlags;
        switch (version) {
            .v1 => {
                if (self.role != .tensor or self.pair_nibble_layout != .none or
                    !allZero(&self.payload_digest))
                {
                    return error.BadVersionedRecord;
                }
                if (self.encoding == .pair_nibble) return error.BadEncoding;
            },
            .v2 => if (require_digest and allZero(&self.payload_digest))
                return error.MissingDigest,
        }
        if (self.out_f == 0 or self.in_f == 0 or self.num_elements == 0)
            return error.BadTensorShape;
        const shape_elements = std.math.mul(u64, self.out_f, self.in_f) catch
            return error.BadTensorShape;
        if (shape_elements != self.num_elements) return error.BadTensorShape;

        switch (self.encoding) {
            .raw_f32 => {
                if (self.role != .tensor or self.packed_layout != .none or
                    self.pair_nibble_layout != .none or self.group_size != 0)
                {
                    return error.BadEncoding;
                }
                if (self.raw.len == 0 or self.packed_bytes.len != 0 or
                    self.scales_f32.len != 0 or self.scales_f16.len != 0 or
                    self.scales_f16_rows4.len != 0)
                {
                    return error.BadEncoding;
                }
                const expected = std.math.mul(u64, self.num_elements, @sizeOf(f32)) catch
                    return error.BadTensorShape;
                if (self.raw.len != expected) return error.BadTensorShape;
            },
            .int4 => {
                if (self.role != .tensor or self.pair_nibble_layout != .none or
                    self.packed_layout == .none or self.group_size == 0 or
                    self.packed_bytes.len == 0 or self.raw.len != 0)
                {
                    return error.BadEncoding;
                }
                const expected_packed = self.num_elements / 2 + self.num_elements % 2;
                if (self.packed_bytes.len != expected_packed) return error.BadTensorShape;
                const groups = self.num_elements / self.group_size +
                    @intFromBool(self.num_elements % self.group_size != 0);
                if (self.scales_f32.len != 0 and
                    self.scales_f32.len != std.math.mul(u64, groups, 4) catch return error.BadTensorShape)
                {
                    return error.BadTensorShape;
                }
                if (self.scales_f16.len != 0 and
                    self.scales_f16.len != std.math.mul(u64, groups, 2) catch return error.BadTensorShape)
                {
                    return error.BadTensorShape;
                }
                if (self.scales_f16_rows4.len != 0 and
                    self.scales_f16_rows4.len != std.math.mul(u64, groups, 2) catch return error.BadTensorShape)
                {
                    return error.BadTensorShape;
                }
                if (self.scales_f32.len == 0 and self.scales_f16.len == 0 and
                    self.scales_f16_rows4.len == 0)
                {
                    return error.MissingScales;
                }
                if (self.packed_layout == .rows4_k16 and
                    (self.out_f % 4 != 0 or self.in_f % 16 != 0 or
                        self.scales_f16_rows4.len == 0))
                {
                    return error.BadPackedLayout;
                }
            },
            .pair_nibble => {
                if (version != .v2 or self.role != .mlp_gate_up_pair)
                    return error.BadRole;
                if (self.packed_layout != .none or
                    self.pair_nibble_layout != .rows4_k16)
                {
                    return error.BadPairNibbleLayout;
                }
                if ((self.group_size != 8 and self.group_size != 16) or
                    self.out_f % 4 != 0 or
                    self.in_f % 16 != 0 or self.in_f % self.group_size != 0)
                {
                    return error.BadTensorShape;
                }
                if (self.raw.len != 0 or self.scales_f32.len != 0 or
                    self.scales_f16.len != 0)
                {
                    return error.BadEncoding;
                }
                // `num_elements` is the coefficient count of either source
                // branch. Each payload byte stores the corresponding gate/up
                // nibble pair, so the exact byte count is `num_elements`.
                if (self.packed_bytes.len != self.num_elements)
                    return error.BadTensorShape;
                const groups_per_row = self.in_f / self.group_size;
                const groups = std.math.mul(u64, self.out_f, groups_per_row) catch
                    return error.BadTensorShape;
                const scale_count = std.math.mul(u64, groups, 2) catch
                    return error.BadTensorShape;
                const scale_bytes = std.math.mul(u64, scale_count, @sizeOf(f16)) catch
                    return error.BadTensorShape;
                if (self.scales_f16_rows4.len != scale_bytes)
                    return error.BadTensorShape;
            },
        }
    }

    fn validateBoundsForVersion(
        self: Record,
        data_offset: u64,
        file_size: u64,
        alignment: u16,
        version: Version,
        require_digest: bool,
    ) !void {
        try self.validateDescriptor(version, require_digest);
        for (all_streams) |stream| {
            const item = self.range(stream);
            if ((item.offset == 0) != (item.len == 0)) return error.BadBounds;
            if (item.len == 0) continue;
            if (item.offset < data_offset or item.offset % alignment != 0)
                return error.BadAlignment;
            const end = std.math.add(u64, item.offset, item.len) catch
                return error.BadBounds;
            if (end > file_size) return error.BadBounds;
        }
        for (all_streams, 0..) |a_stream, a_index| {
            const a = self.range(a_stream);
            if (a.len == 0) continue;
            for (all_streams[a_index + 1 ..]) |b_stream| {
                const b = self.range(b_stream);
                if (b.len != 0 and rangesOverlap(a, b)) return error.OverlappingPayload;
            }
        }
    }

    pub fn validateBounds(
        self: Record,
        data_offset: u64,
        file_size: u64,
        alignment: u16,
    ) !void {
        return self.validateBoundsForVersion(
            data_offset,
            file_size,
            alignment,
            .v2,
            true,
        );
    }
};

pub const WriteRecord = struct {
    key: RecordKey,
    role: Role = .tensor,
    encoding: Encoding,
    packed_layout: PackedLayout,
    pair_nibble_layout: PairNibbleLayout = .none,
    group_size: u32,
    out_f: u32,
    in_f: u32,
    num_elements: u64,
    flags: u32 = 0,
    packed_bytes: []const u8 = &.{},
    scales_f32: []const u8 = &.{},
    scales_f16: []const u8 = &.{},
    scales_f16_rows4: []const u8 = &.{},
    raw: []const u8 = &.{},

    pub fn bytes(self: WriteRecord, stream: Stream) []const u8 {
        return switch (stream) {
            .packed_weights => self.packed_bytes,
            .scales_f32 => self.scales_f32,
            .scales_f16 => self.scales_f16,
            .scales_f16_rows4 => self.scales_f16_rows4,
            .raw => self.raw,
        };
    }
};

pub const WriteOptions = struct {
    config: ConfigSnapshot,
    source_fingerprint: [32]u8,
    abi_fingerprint: [32]u8 = ABI_FINGERPRINT,
    sync: bool = true,
};

/// One record returned by a just-in-time payload provider. Providers may
/// reuse the same backing workspace after this record has been consumed: the
/// atomic writer computes both integrity domains and writes every stream
/// before requesting the next record.
pub const MaterializedWriteRecord = struct {
    record: WriteRecord,
    generated: bool = false,
    /// Peak live anonymous workspace attributable to generating this record.
    /// Borrowed records report zero. This value is evidence only; exact stream
    /// extents remain independently checked against the planned record.
    workspace_bytes: u64 = 0,
};

pub const WriteRecordProvider = struct {
    context: *anyopaque,
    materialize: *const fn (
        context: *anyopaque,
        record_index: usize,
        planned: WriteRecord,
    ) anyerror!MaterializedWriteRecord,
    finish: ?*const fn (context: *anyopaque) anyerror!void = null,
};

/// Exact generated-record ledger returned by the streamed writer. `total` is
/// the sum of per-record work, while `peak` is the maximum live workspace and
/// is therefore the preparation-memory bound relevant to a reusable buffer.
pub const WriteStats = struct {
    generated_records: u64 = 0,
    generated_workspace_bytes_total: u64 = 0,
    generated_workspace_bytes_peak: u64 = 0,
};

pub const OpenOptions = struct {
    /// CRC remains available for fast accidental-corruption checks.
    verify_payload_crc: bool = true,
    /// V2 descriptor+payload SHA-256 verification is independently fail-closed
    /// by default. V1 has no per-record digest and therefore relies on CRC.
    verify_payload_digest: bool = true,
    allow_v1: bool = true,
    expected_source_fingerprint: ?[32]u8 = null,
    /// Expected current-writer (v2) ABI.
    expected_abi_fingerprint: ?[32]u8 = ABI_FINGERPRINT,
    /// Expected read-only legacy ABI. Kept separate so v1/v2 fingerprints can
    /// never be accepted interchangeably.
    expected_v1_abi_fingerprint: ?[32]u8 = ABI_FINGERPRINT_V1,
};

pub const Int4Slices = struct {
    packed_bytes: []const u8,
    scales_f32: []const f32,
    scales_f16: []const f16,
    scales_f16_rows4: []const f16,
};

pub const PairNibbleSlices = struct {
    /// One byte per coefficient coordinate: low nibble is gate, high nibble is
    /// up. `Record.num_elements` is the coefficient count of either branch.
    packed_pairs: []const u8,
    /// Exactly two FP16 scales per quantization group, in rows4 layout order.
    scales_f16_rows4: []const f16,
};

/// Cross-platform, read-only file mapping used by runtime images and tooling.
///
/// POSIX targets retain the direct `mmap` path. Windows uses an NT read-only
/// section view so large model files remain demand-paged instead of being
/// copied into an owned heap buffer.
pub const ReadOnlyFileMapping = struct {
    bytes: []align(std.heap.page_size_min) const u8,
    platform_handle: if (builtin.os.tag == .windows)
        std.os.windows.HANDLE
    else
        void,

    pub fn init(file: std.fs.File, len: usize) !ReadOnlyFileMapping {
        if (len == 0) return error.EmptyFile;
        if (comptime builtin.os.tag == .windows) {
            const windows = std.os.windows;
            var section_handle: windows.HANDLE = undefined;
            const create_status = windows.ntdll.NtCreateSection(
                &section_handle,
                windows.STANDARD_RIGHTS_REQUIRED |
                    windows.SECTION_QUERY |
                    windows.SECTION_MAP_READ,
                null,
                null,
                windows.PAGE_READONLY,
                windows.SEC_COMMIT,
                file.handle,
            );
            if (create_status != .SUCCESS)
                return windows.unexpectedStatus(create_status);
            errdefer windows.CloseHandle(section_handle);

            const process_handle = windows.GetCurrentProcess();
            var base_address: usize = 0;
            var view_size: usize = len;
            const map_status = windows.ntdll.NtMapViewOfSection(
                section_handle,
                process_handle,
                @ptrCast(&base_address),
                null,
                0,
                null,
                &view_size,
                .ViewUnmap,
                0,
                windows.PAGE_READONLY,
            );
            if (map_status != .SUCCESS)
                return windows.unexpectedStatus(map_status);
            if (base_address == 0) return error.InvalidMapping;
            errdefer std.debug.assert(
                windows.ntdll.NtUnmapViewOfSection(
                    process_handle,
                    @ptrFromInt(base_address),
                ) == .SUCCESS,
            );
            if (view_size < len) return error.InvalidMapping;

            const bytes = @as(
                [*]align(std.heap.page_size_min) const u8,
                @ptrFromInt(base_address),
            )[0..len];
            return .{
                .bytes = bytes,
                .platform_handle = section_handle,
            };
        }

        const mapped = try std.posix.mmap(
            null,
            len,
            std.posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        );
        return .{
            .bytes = mapped,
            .platform_handle = {},
        };
    }

    pub fn close(self: ReadOnlyFileMapping) void {
        if (comptime builtin.os.tag == .windows) {
            const windows = std.os.windows;
            const status = windows.ntdll.NtUnmapViewOfSection(
                windows.GetCurrentProcess(),
                @ptrCast(@constCast(self.bytes.ptr)),
            );
            std.debug.assert(status == .SUCCESS);
            windows.CloseHandle(self.platform_handle);
        } else {
            std.posix.munmap(self.bytes);
        }
    }
};

pub const MappedImage = struct {
    file: std.fs.File,
    mapped: []align(std.heap.page_size_min) const u8,
    mapping_handle: if (builtin.os.tag == .windows)
        std.os.windows.HANDLE
    else
        void,
    header: Header,

    pub fn open(path: []const u8) !MappedImage {
        return openWithOptions(path, .{});
    }

    pub fn openWithOptions(path: []const u8, options: OpenOptions) !MappedImage {
        return openWithOptionsAt(std.fs.cwd(), path, options);
    }

    pub fn openAt(dir: std.fs.Dir, path: []const u8) !MappedImage {
        return openWithOptionsAt(dir, path, .{});
    }

    pub fn openWithOptionsAt(
        dir: std.fs.Dir,
        path: []const u8,
        options: OpenOptions,
    ) !MappedImage {
        const file = try dir.openFile(path, .{});
        errdefer file.close();
        const stat = try file.stat();
        if (stat.size < HEADER_SIZE) return error.TruncatedHeader;
        const map_len = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
        const mapping = try ReadOnlyFileMapping.init(file, map_len);
        errdefer mapping.close();
        const mapped = mapping.bytes;

        const header = try Header.decode(mapped[0..HEADER_SIZE]);
        try validateHeaderBytes(mapped[0..HEADER_SIZE], header, stat.size, options);
        var image: MappedImage = .{
            .file = file,
            .mapped = mapped,
            .mapping_handle = mapping.platform_handle,
            .header = header,
        };
        try image.validateIndexAndRecords(options);
        return image;
    }

    pub fn close(self: *MappedImage) void {
        ReadOnlyFileMapping.close(.{
            .bytes = self.mapped,
            .platform_handle = self.mapping_handle,
        });
        self.file.close();
        self.* = undefined;
    }

    pub fn recordCount(self: *const MappedImage) usize {
        return @intCast(self.header.record_count);
    }

    pub fn recordAt(self: *const MappedImage, index: usize) !Record {
        if (index >= self.recordCount()) return error.IndexOutOfBounds;
        const record_size = recordSizeFor(self.header.version);
        const start_u64 = std.math.add(
            u64,
            self.header.index_offset,
            std.math.mul(u64, index, record_size) catch return error.BadBounds,
        ) catch return error.BadBounds;
        const start: usize = @intCast(start_u64);
        return Record.decode(self.mapped[start .. start + record_size], self.header.version);
    }

    pub fn find(
        self: *const MappedImage,
        layer_idx: u32,
        kind: fmt.TensorKind,
    ) ?Record {
        return self.findWithRole(layer_idx, kind, .tensor);
    }

    pub fn findWithRole(
        self: *const MappedImage,
        layer_idx: u32,
        kind: fmt.TensorKind,
        role: Role,
    ) ?Record {
        const wanted: RecordKey = .{ .layer_idx = layer_idx, .kind = kind };
        for (0..self.recordCount()) |index| {
            const record = self.recordAt(index) catch unreachable;
            if (record.role == role and record.key.eql(wanted)) return record;
        }
        return null;
    }

    /// Non-tensor execution roles are unique per layer and can be resolved
    /// without coupling them to a source `TensorKind`.
    pub fn findRole(
        self: *const MappedImage,
        layer_idx: u32,
        role: Role,
    ) ?Record {
        for (0..self.recordCount()) |index| {
            const record = self.recordAt(index) catch unreachable;
            if (record.key.layer_idx == layer_idx and record.role == role)
                return record;
        }
        return null;
    }

    pub fn bytes(self: *const MappedImage, record: Record, stream: Stream) ![]const u8 {
        const item = record.range(stream);
        if (item.len == 0) return &.{};
        const start = std.math.cast(usize, item.offset) orelse return error.BadBounds;
        const len = std.math.cast(usize, item.len) orelse return error.BadBounds;
        const end = std.math.add(usize, start, len) catch return error.BadBounds;
        if (start < self.header.data_offset or end > self.mapped.len) return error.BadBounds;
        return self.mapped[start..end];
    }

    pub fn f32View(
        self: *const MappedImage,
        record: Record,
        stream: Stream,
    ) ![]const f32 {
        if (stream != .raw and stream != .scales_f32) return error.WrongStreamType;
        const raw_bytes = try self.bytes(record, stream);
        return typedView(f32, raw_bytes);
    }

    pub fn f16View(
        self: *const MappedImage,
        record: Record,
        stream: Stream,
    ) ![]const f16 {
        if (stream != .scales_f16 and stream != .scales_f16_rows4)
            return error.WrongStreamType;
        const raw_bytes = try self.bytes(record, stream);
        return typedView(f16, raw_bytes);
    }

    pub fn int4Slices(self: *const MappedImage, record: Record) !Int4Slices {
        if (record.encoding != .int4) return error.BadEncoding;
        return .{
            .packed_bytes = try self.bytes(record, .packed_weights),
            .scales_f32 = try self.f32View(record, .scales_f32),
            .scales_f16 = try self.f16View(record, .scales_f16),
            .scales_f16_rows4 = try self.f16View(record, .scales_f16_rows4),
        };
    }

    pub fn pairNibbleSlices(
        self: *const MappedImage,
        record: Record,
    ) !PairNibbleSlices {
        if (record.encoding != .pair_nibble or
            record.role != .mlp_gate_up_pair)
        {
            return error.BadEncoding;
        }
        return .{
            .packed_pairs = try self.bytes(record, .packed_weights),
            .scales_f16_rows4 = try self.f16View(record, .scales_f16_rows4),
        };
    }

    pub fn verifyAll(self: *const MappedImage) !void {
        for (0..self.recordCount()) |index| {
            const record = try self.recordAt(index);
            try self.verifyRecord(record, true, true);
        }
    }

    fn verifyRecord(
        self: *const MappedImage,
        record: Record,
        verify_payload_crc: bool,
        verify_payload_digest: bool,
    ) !void {
        if (verify_payload_crc) {
            var crc = accelerated_crc32.Hasher.init();
            for (all_streams) |stream| crc.update(try self.bytes(record, stream));
            if (crc.final() != record.payload_crc32) return error.CrcMismatch;
        }
        if (verify_payload_digest and self.header.version == .v2) {
            const actual = try digestMappedRecord(self, record);
            if (!std.mem.eql(u8, &actual, &record.payload_digest))
                return error.DigestMismatch;
        }
    }

    fn validateIndexAndRecords(self: *const MappedImage, options: OpenOptions) !void {
        const record_size = recordSizeFor(self.header.version);
        const index_len_u64 = std.math.mul(
            u64,
            self.header.record_count,
            record_size,
        ) catch return error.BadBounds;
        const index_end_u64 = std.math.add(
            u64,
            self.header.index_offset,
            index_len_u64,
        ) catch return error.BadBounds;
        const index_start = std.math.cast(usize, self.header.index_offset) orelse
            return error.BadBounds;
        const index_end = std.math.cast(usize, index_end_u64) orelse
            return error.BadBounds;
        if (index_end > self.mapped.len) return error.BadBounds;
        if (std.hash.Crc32.hash(self.mapped[index_start..index_end]) != self.header.index_crc32)
            return error.IndexCrcMismatch;

        for (0..self.recordCount()) |index| {
            const record = try self.recordAt(index);
            try record.validateBoundsForVersion(
                self.header.data_offset,
                self.header.file_size,
                DATA_ALIGNMENT,
                self.header.version,
                true,
            );
            for (0..index) |previous_index| {
                const previous = try self.recordAt(previous_index);
                if (Record.identityEql(record, previous)) return error.DuplicateRecord;
                for (all_streams) |stream| {
                    const current_range = record.range(stream);
                    if (current_range.len == 0) continue;
                    for (all_streams) |previous_stream| {
                        const previous_range = previous.range(previous_stream);
                        if (previous_range.len != 0 and rangesOverlap(current_range, previous_range))
                            return error.OverlappingPayload;
                    }
                }
            }
            try self.verifyRecord(
                record,
                options.verify_payload_crc,
                options.verify_payload_digest,
            );
        }
    }
};

pub fn writeAtomic(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: WriteOptions,
    input_records: []const WriteRecord,
) !void {
    return writeAtomicAt(allocator, std.fs.cwd(), path, options, input_records);
}

pub fn writeAtomicAt(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    path: []const u8,
    options: WriteOptions,
    input_records: []const WriteRecord,
) !void {
    _ = try writeAtomicWithProviderAt(
        allocator,
        dir,
        path,
        options,
        input_records,
        null,
    );
}

/// Write a current GLRT image while allowing selected records to be generated
/// just in time from reusable caller-owned storage. The final file is byte-for-
/// byte identical to the eager writer for the same records and payload bytes.
///
/// Header and index space is reserved with zeros in the unpublished atomic
/// temporary. Each record is then materialized, CRC-scanned, SHA-scanned while
/// being written, and released before the next provider call. Once every
/// digest is known, the finalized index and header are positioned-writes into
/// the temporary, followed by the existing sync+rename publication sequence.
pub fn writeAtomicWithProvider(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: WriteOptions,
    input_records: []const WriteRecord,
    provider: ?WriteRecordProvider,
) !WriteStats {
    return writeAtomicWithProviderAt(
        allocator,
        std.fs.cwd(),
        path,
        options,
        input_records,
        provider,
    );
}

pub fn writeAtomicWithProviderAt(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    path: []const u8,
    options: WriteOptions,
    input_records: []const WriteRecord,
    provider: ?WriteRecordProvider,
) !WriteStats {
    try options.config.validate();
    if (input_records.len == 0) return error.NoRecords;

    const planned = try allocator.alloc(Record, input_records.len);
    defer allocator.free(planned);

    const index_len = std.math.mul(usize, input_records.len, RECORD_SIZE) catch
        return error.IndexTooLarge;
    var cursor = try alignForward(
        std.math.add(u64, HEADER_SIZE, index_len) catch return error.IndexTooLarge,
        DATA_ALIGNMENT,
    );
    const data_offset = cursor;

    for (input_records, 0..) |input, index| {
        for (input_records[0..index]) |previous| {
            if (writeRecordIdentityEql(input, previous)) return error.DuplicateRecord;
        }
        var record: Record = .{
            .key = input.key,
            .role = input.role,
            .encoding = input.encoding,
            .packed_layout = input.packed_layout,
            .pair_nibble_layout = input.pair_nibble_layout,
            .group_size = input.group_size,
            .out_f = input.out_f,
            .in_f = input.in_f,
            .flags = input.flags,
            .num_elements = input.num_elements,
            .payload_crc32 = 0,
        };
        for (all_streams) |stream| {
            const payload = input.bytes(stream);
            if (payload.len == 0) continue;
            cursor = try alignForward(cursor, DATA_ALIGNMENT);
            record.setRange(stream, .{ .offset = cursor, .len = payload.len });
            cursor = std.math.add(u64, cursor, payload.len) catch return error.FileTooLarge;
        }
        planned[index] = record;
    }
    const file_size = try alignForward(cursor, DATA_ALIGNMENT);
    for (planned) |record| {
        try record.validateBoundsForVersion(
            data_offset,
            file_size,
            DATA_ALIGNMENT,
            .v2,
            false,
        );
    }

    var write_buffer: [64 * 1024]u8 = undefined;
    var atomic = try dir.atomicFile(path, .{ .write_buffer = &write_buffer });
    defer atomic.deinit();
    const writer = &atomic.file_writer.interface;
    var written: u64 = 0;
    // Header, index and their alignment gap are backpatched only after every
    // generated payload has supplied its CRC and descriptor-bound digest.
    try padWriterTo(writer, &written, data_offset);

    var stats: WriteStats = .{};
    for (planned, input_records, 0..) |*plan, input, index| {
        const materialized = if (provider) |active|
            try active.materialize(active.context, index, input)
        else
            MaterializedWriteRecord{ .record = input };
        if (!writeRecordPlanEql(input, materialized.record))
            return error.ProviderRecordMismatch;
        if (!materialized.generated and materialized.workspace_bytes != 0)
            return error.BadProviderTelemetry;

        if (materialized.generated) {
            stats.generated_records = std.math.add(
                u64,
                stats.generated_records,
                1,
            ) catch return error.StatsOverflow;
            stats.generated_workspace_bytes_total = std.math.add(
                u64,
                stats.generated_workspace_bytes_total,
                materialized.workspace_bytes,
            ) catch return error.StatsOverflow;
            stats.generated_workspace_bytes_peak = @max(
                stats.generated_workspace_bytes_peak,
                materialized.workspace_bytes,
            );
        }

        plan.payload_crc32 = crcWriteRecord(materialized.record);
        var digest = std.crypto.hash.sha2.Sha256.init(.{});
        const descriptor = plan.encode(.v2);
        digest.update(descriptor[0..V2_DIGEST_OFFSET]);
        for (all_streams) |stream| {
            const payload = materialized.record.bytes(stream);
            if (payload.len == 0) continue;
            try padWriterTo(writer, &written, plan.range(stream).offset);
            digest.update(payload);
            try writer.writeAll(payload);
            written += payload.len;
        }
        digest.final(&plan.payload_digest);
        try plan.validateBoundsForVersion(
            data_offset,
            file_size,
            DATA_ALIGNMENT,
            .v2,
            true,
        );
    }
    if (provider) |active| {
        if (active.finish) |finish| try finish(active.context);
    }
    try padWriterTo(writer, &written, file_size);
    try atomic.flush();

    const index_bytes = try allocator.alloc(u8, index_len);
    defer allocator.free(index_bytes);
    for (planned, 0..) |record, index| {
        const encoded = record.encode(.v2);
        @memcpy(index_bytes[index * RECORD_SIZE ..][0..RECORD_SIZE], &encoded);
    }

    var header: Header = .{
        .version = .v2,
        .record_count = input_records.len,
        .data_offset = data_offset,
        .file_size = file_size,
        .source_fingerprint = options.source_fingerprint,
        .abi_fingerprint = options.abi_fingerprint,
        .config = options.config,
        .index_crc32 = std.hash.Crc32.hash(index_bytes),
        .header_crc32 = 0,
    };
    var encoded_header = header.encode();
    header.header_crc32 = std.hash.Crc32.hash(&encoded_header);
    encoded_header = header.encode();

    try atomic.file_writer.file.pwriteAll(index_bytes, HEADER_SIZE);
    try atomic.file_writer.file.pwriteAll(&encoded_header, 0);
    if (options.sync) try atomic.file_writer.file.sync();
    try atomic.renameIntoPlace();
    return stats;
}

/// Stable helper for deriving a source or policy fingerprint.
pub fn fingerprint(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

fn validateHeaderBytes(
    bytes: []const u8,
    header: Header,
    actual_file_size: u64,
    options: OpenOptions,
) !void {
    var header_bytes: [HEADER_SIZE]u8 = undefined;
    @memcpy(&header_bytes, bytes[0..HEADER_SIZE]);
    @memset(header_bytes[HEADER_CRC_OFFSET..][0..4], 0);
    if (std.hash.Crc32.hash(&header_bytes) != header.header_crc32)
        return error.HeaderCrcMismatch;
    if (header.version == .v1 and !options.allow_v1)
        return error.LegacyVersionDisabled;
    if (header.flags != 0 or header.record_count == 0) return error.BadHeader;
    if (header.index_offset != HEADER_SIZE or header.file_size != actual_file_size)
        return error.BadBounds;
    const index_len = std.math.mul(
        u64,
        header.record_count,
        recordSizeFor(header.version),
    ) catch return error.BadBounds;
    const index_end = std.math.add(u64, header.index_offset, index_len) catch
        return error.BadBounds;
    if (header.data_offset < index_end or header.data_offset % DATA_ALIGNMENT != 0 or
        header.data_offset > header.file_size)
    {
        return error.BadAlignment;
    }
    if (options.expected_source_fingerprint) |expected| {
        if (!std.mem.eql(u8, &expected, &header.source_fingerprint))
            return error.SourceFingerprintMismatch;
    }
    const expected_abi = switch (header.version) {
        .v1 => options.expected_v1_abi_fingerprint,
        .v2 => options.expected_abi_fingerprint,
    };
    if (expected_abi) |expected| {
        if (!std.mem.eql(u8, &expected, &header.abi_fingerprint))
            return error.AbiFingerprintMismatch;
    }
}

fn writeRecordIdentityEql(a: WriteRecord, b: WriteRecord) bool {
    if (a.key.layer_idx != b.key.layer_idx or a.role != b.role) return false;
    return a.role != .tensor or a.key.kind == b.key.kind;
}

fn writeRecordPlanEql(a: WriteRecord, b: WriteRecord) bool {
    if (a.key.layer_idx != b.key.layer_idx or a.key.kind != b.key.kind or
        a.role != b.role or a.encoding != b.encoding or
        a.packed_layout != b.packed_layout or
        a.pair_nibble_layout != b.pair_nibble_layout or
        a.group_size != b.group_size or a.out_f != b.out_f or
        a.in_f != b.in_f or a.num_elements != b.num_elements or
        a.flags != b.flags)
    {
        return false;
    }
    for (all_streams) |stream| {
        if (a.bytes(stream).len != b.bytes(stream).len) return false;
    }
    return true;
}

fn crcWriteRecord(record: WriteRecord) u32 {
    var crc = accelerated_crc32.Hasher.init();
    for (all_streams) |stream| crc.update(record.bytes(stream));
    return crc.final();
}

fn digestMappedRecord(image: *const MappedImage, record: Record) ![32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const encoded = record.encode(.v2);
    hash.update(encoded[0..V2_DIGEST_OFFSET]);
    for (all_streams) |stream| hash.update(try image.bytes(record, stream));
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn typedView(comptime T: type, bytes: []const u8) ![]const T {
    if (bytes.len == 0) return &.{};
    if (builtin.target.cpu.arch.endian() != .little) return error.UnsupportedEndian;
    if (bytes.len % @sizeOf(T) != 0) return error.BadTensorShape;
    const aligned: []align(@alignOf(T)) const u8 = @alignCast(bytes);
    return std.mem.bytesAsSlice(T, aligned);
}

fn encodeRange(out: []u8, item: SliceRange) void {
    putInt(u64, out[0..8], item.offset);
    putInt(u64, out[8..16], item.len);
}

fn decodeRange(bytes: []const u8) SliceRange {
    return .{
        .offset = getInt(u64, bytes[0..8]),
        .len = getInt(u64, bytes[8..16]),
    };
}

fn rangesOverlap(a: SliceRange, b: SliceRange) bool {
    const a_end = a.offset + a.len;
    const b_end = b.offset + b.len;
    return a.offset < b_end and b.offset < a_end;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn alignForward(value: u64, alignment: u16) !u64 {
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.BadAlignment;
    const mask: u64 = alignment - 1;
    const with_mask = std.math.add(u64, value, mask) catch return error.FileTooLarge;
    return with_mask & ~mask;
}

fn padWriterTo(writer: *std.Io.Writer, written: *u64, target: u64) !void {
    if (written.* > target) return error.BadBounds;
    const zeros: [4096]u8 = @splat(0);
    while (written.* < target) {
        const remaining = target - written.*;
        const amount: usize = @intCast(@min(remaining, zeros.len));
        try writer.writeAll(zeros[0..amount]);
        written.* += amount;
    }
}

fn putInt(comptime T: type, out: []u8, value: T) void {
    std.mem.writeInt(T, out[0..@sizeOf(T)], value, .little);
}

fn getInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

// --------------------------------------------------------------------------
// Focused codec tests
// --------------------------------------------------------------------------

const testing = std.testing;

fn testConfig() ConfigSnapshot {
    return .{
        .dim = 16,
        .hidden_dim = 32,
        .layers = 2,
        .vocab = 64,
        .heads = 2,
        .head_dim = 8,
        .kv_heads = 1,
        .rms_eps = 1e-6,
        .rope_theta = 10_000,
        .tie_embeddings = true,
    };
}

fn writeLegacyV1RawImage(
    dir: std.fs.Dir,
    path: []const u8,
    source_fingerprint: [32]u8,
    values: []const f32,
) !void {
    const payload = std.mem.sliceAsBytes(values);
    const data_offset: u64 = HEADER_SIZE + V1_RECORD_SIZE;
    const file_size = try alignForward(data_offset + payload.len, DATA_ALIGNMENT);

    var crc = accelerated_crc32.Hasher.init();
    crc.update(payload);
    const record: Record = .{
        .key = .{ .layer_idx = 0, .kind = .final_norm },
        .encoding = .raw_f32,
        .packed_layout = .none,
        .group_size = 0,
        .out_f = 1,
        .in_f = @intCast(values.len),
        .num_elements = values.len,
        .raw = .{ .offset = data_offset, .len = payload.len },
        .payload_crc32 = crc.final(),
    };
    const encoded_record = record.encode(.v1);
    const index_crc32 = std.hash.Crc32.hash(encoded_record[0..V1_RECORD_SIZE]);
    var header: Header = .{
        .version = .v1,
        .record_count = 1,
        .data_offset = data_offset,
        .file_size = file_size,
        .source_fingerprint = source_fingerprint,
        .abi_fingerprint = ABI_FINGERPRINT_V1,
        .config = testConfig(),
        .index_crc32 = index_crc32,
        .header_crc32 = 0,
    };
    var encoded_header = header.encode();
    header.header_crc32 = std.hash.Crc32.hash(&encoded_header);
    encoded_header = header.encode();

    const file = try dir.createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(&encoded_header);
    try file.writeAll(encoded_record[0..V1_RECORD_SIZE]);
    try file.writeAll(payload);
    const tail_len: usize = @intCast(file_size - data_offset - payload.len);
    const zeros: [DATA_ALIGNMENT]u8 = @splat(0);
    try file.writeAll(zeros[0..tail_len]);
}

fn repairSingleV2IndexAndHeaderCrc(dir: std.fs.Dir, path: []const u8) !void {
    const file = try dir.openFile(path, .{ .mode = .read_write });
    defer file.close();

    var header_bytes: [HEADER_SIZE]u8 = undefined;
    if (try file.preadAll(&header_bytes, 0) != HEADER_SIZE) return error.TruncatedHeader;
    var index_bytes: [RECORD_SIZE]u8 = undefined;
    if (try file.preadAll(&index_bytes, HEADER_SIZE) != RECORD_SIZE)
        return error.TruncatedIndex;

    putInt(u32, header_bytes[152..156], std.hash.Crc32.hash(&index_bytes));
    @memset(header_bytes[HEADER_CRC_OFFSET..][0..4], 0);
    putInt(u32, header_bytes[HEADER_CRC_OFFSET..][0..4], std.hash.Crc32.hash(&header_bytes));
    if (try file.pwrite(&header_bytes, 0) != HEADER_SIZE) return error.ShortWrite;
}

test "atomic runtime image round-trip exposes mapped typed views" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const raw_values = [_]f32{ 1.25, -2.5, 3.75, 4.0 };
    const packed_data = [_]u8{ 0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe };
    const scale_values = [_]f32{0.5};
    const scale_f16 = [_]f16{0.5};
    const records = [_]WriteRecord{
        .{
            .key = .{ .layer_idx = 0, .kind = .final_norm },
            .encoding = .raw_f32,
            .packed_layout = .none,
            .group_size = 0,
            .out_f = 1,
            .in_f = raw_values.len,
            .num_elements = raw_values.len,
            .raw = std.mem.sliceAsBytes(&raw_values),
        },
        .{
            .key = .{ .layer_idx = 0, .kind = .attn_q },
            .encoding = .int4,
            .packed_layout = .row_major,
            .group_size = 16,
            .out_f = 1,
            .in_f = 16,
            .num_elements = 16,
            .packed_bytes = &packed_data,
            .scales_f32 = std.mem.sliceAsBytes(&scale_values),
            .scales_f16 = std.mem.sliceAsBytes(&scale_f16),
        },
    };
    const source_fingerprint = fingerprint("source-model");
    try writeAtomicAt(testing.allocator, tmp.dir, "model.glrt", .{
        .config = testConfig(),
        .source_fingerprint = source_fingerprint,
        .sync = false,
    }, &records);

    var image = try MappedImage.openWithOptionsAt(tmp.dir, "model.glrt", .{
        .expected_source_fingerprint = source_fingerprint,
    });
    defer image.close();
    try testing.expectEqual(Version.v2, image.header.version);
    try testing.expectEqual(@as(u16, VERSION), getInt(u16, image.mapped[4..6]));
    try testing.expectEqual(@as(u16, RECORD_SIZE), getInt(u16, image.mapped[8..10]));
    try testing.expectEqual(@as(usize, 2), image.recordCount());
    try testing.expectEqual(@as(u64, 0), image.header.file_size % DATA_ALIGNMENT);

    const raw_record = image.find(0, .final_norm) orelse return error.MissingRecord;
    try testing.expectEqual(Role.tensor, raw_record.role);
    try testing.expectEqual(PairNibbleLayout.none, raw_record.pair_nibble_layout);
    try testing.expect(!allZero(&raw_record.payload_digest));
    const raw_view = try image.f32View(raw_record, .raw);
    try testing.expectEqualSlices(f32, &raw_values, raw_view);
    try testing.expectEqual(@as(u64, 0), raw_record.raw.offset % DATA_ALIGNMENT);

    const int4_record = image.find(0, .attn_q) orelse return error.MissingRecord;
    const int4 = try image.int4Slices(int4_record);
    try testing.expectEqualSlices(u8, &packed_data, int4.packed_bytes);
    try testing.expectEqualSlices(f32, &scale_values, int4.scales_f32);
    try testing.expectEqualSlices(f16, &scale_f16, int4.scales_f16);
    try testing.expectEqual(@as(usize, 0), int4.scales_f16_rows4.len);
}

test "record-at-a-time provider is byte-identical and reports bounded workspace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const raw_values = [_]f32{ 1.25, -2.5, 3.75, 4.0 };
    const packed_data = [_]u8{0x71} ** 8;
    const scale_values = [_]f32{0.5};
    const records = [_]WriteRecord{
        .{
            .key = .{ .layer_idx = 0, .kind = .final_norm },
            .encoding = .raw_f32,
            .packed_layout = .none,
            .group_size = 0,
            .out_f = 1,
            .in_f = raw_values.len,
            .num_elements = raw_values.len,
            .raw = std.mem.sliceAsBytes(&raw_values),
        },
        .{
            .key = .{ .layer_idx = 0, .kind = .attn_q },
            .encoding = .int4,
            .packed_layout = .row_major,
            .group_size = 16,
            .out_f = 1,
            .in_f = 16,
            .num_elements = 16,
            .packed_bytes = &packed_data,
            .scales_f32 = std.mem.sliceAsBytes(&scale_values),
        },
    };
    const options: WriteOptions = .{
        .config = testConfig(),
        .source_fingerprint = fingerprint("streamed-byte-identity"),
        .sync = false,
    };
    try writeAtomicAt(testing.allocator, tmp.dir, "eager.glrt", options, &records);

    const Provider = struct {
        fn materialize(
            _: *anyopaque,
            index: usize,
            planned: WriteRecord,
        ) anyerror!MaterializedWriteRecord {
            return .{
                .record = planned,
                .generated = index == 1,
                .workspace_bytes = if (index == 1) 123 else 0,
            };
        }
    };
    var context: u8 = 0;
    const stats = try writeAtomicWithProviderAt(
        testing.allocator,
        tmp.dir,
        "streamed.glrt",
        options,
        &records,
        .{ .context = &context, .materialize = Provider.materialize },
    );
    try testing.expectEqual(@as(u64, 1), stats.generated_records);
    try testing.expectEqual(
        @as(u64, 123),
        stats.generated_workspace_bytes_total,
    );
    try testing.expectEqual(
        @as(u64, 123),
        stats.generated_workspace_bytes_peak,
    );

    const eager = try tmp.dir.readFileAlloc(
        testing.allocator,
        "eager.glrt",
        16 * 1024,
    );
    defer testing.allocator.free(eager);
    const streamed = try tmp.dir.readFileAlloc(
        testing.allocator,
        "streamed.glrt",
        16 * 1024,
    );
    defer testing.allocator.free(streamed);
    try testing.expectEqualSlices(u8, eager, streamed);
}

test "provider failure preserves the old destination" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const old_destination = "prior-complete-runtime-image";
    try tmp.dir.writeFile(.{
        .sub_path = "model.glrt",
        .data = old_destination,
    });
    const first = [_]f32{ 1, 2, 3, 4 };
    const second = [_]f32{ 5, 6, 7, 8 };
    const records = [_]WriteRecord{
        .{
            .key = .{ .layer_idx = 0, .kind = .final_norm },
            .encoding = .raw_f32,
            .packed_layout = .none,
            .group_size = 0,
            .out_f = 1,
            .in_f = first.len,
            .num_elements = first.len,
            .raw = std.mem.sliceAsBytes(&first),
        },
        .{
            .key = .{ .layer_idx = 0, .kind = .input_norm },
            .encoding = .raw_f32,
            .packed_layout = .none,
            .group_size = 0,
            .out_f = 1,
            .in_f = second.len,
            .num_elements = second.len,
            .raw = std.mem.sliceAsBytes(&second),
        },
    };
    const Provider = struct {
        fn materialize(
            _: *anyopaque,
            index: usize,
            planned: WriteRecord,
        ) anyerror!MaterializedWriteRecord {
            if (index == 1) return error.InjectedFailure;
            return .{ .record = planned };
        }
    };
    var context: u8 = 0;
    try testing.expectError(
        error.InjectedFailure,
        writeAtomicWithProviderAt(
            testing.allocator,
            tmp.dir,
            "model.glrt",
            .{
                .config = testConfig(),
                .source_fingerprint = fingerprint("failed-stream"),
                .sync = false,
            },
            &records,
            .{ .context = &context, .materialize = Provider.materialize },
        ),
    );
    const retained = try tmp.dir.readFileAlloc(
        testing.allocator,
        "model.glrt",
        1024,
    );
    defer testing.allocator.free(retained);
    try testing.expectEqualStrings(old_destination, retained);
}

test "reader preserves explicit read-only GLRT v1 compatibility" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const values = [_]f32{ 1.5, -2.0, 3.25, 4.5 };
    const source_fingerprint = fingerprint("legacy-source");
    try writeLegacyV1RawImage(tmp.dir, "legacy.glrt", source_fingerprint, &values);

    var image = try MappedImage.openWithOptionsAt(tmp.dir, "legacy.glrt", .{
        .expected_source_fingerprint = source_fingerprint,
    });
    defer image.close();
    try testing.expectEqual(Version.v1, image.header.version);
    try testing.expectEqual(@as(u16, V1_RECORD_SIZE), getInt(u16, image.mapped[8..10]));
    const record = image.find(0, .final_norm) orelse return error.MissingRecord;
    try testing.expectEqual(Role.tensor, record.role);
    try testing.expectEqual(PairNibbleLayout.none, record.pair_nibble_layout);
    try testing.expect(allZero(&record.payload_digest));
    try testing.expectEqualSlices(f32, &values, try image.f32View(record, .raw));

    try testing.expectError(
        error.LegacyVersionDisabled,
        MappedImage.openWithOptionsAt(tmp.dir, "legacy.glrt", .{ .allow_v1 = false }),
    );
    var wrong_v1_abi = ABI_FINGERPRINT_V1;
    wrong_v1_abi[0] ^= 0xff;
    try testing.expectError(
        error.AbiFingerprintMismatch,
        MappedImage.openWithOptionsAt(tmp.dir, "legacy.glrt", .{
            .expected_v1_abi_fingerprint = wrong_v1_abi,
        }),
    );
}

test "PairNibble v2 role round-trip has exact paired geometry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pair_bytes: [64]u8 = undefined;
    for (&pair_bytes, 0..) |*byte, index| {
        const gate: u8 = @intCast(index & 0x0f);
        const up: u8 = @intCast((index + 3) & 0x0f);
        byte.* = gate | (up << 4);
    }
    // out_f=4, in_f=16, g8 => 8 groups, exactly two scales per group.
    const pair_scales = [_]f16{
        0.25, 0.5, 0.75, 1.0,
        1.25, 1.5, 1.75, 2.0,
        2.25, 2.5, 2.75, 3.0,
        3.25, 3.5, 3.75, 4.0,
    };
    const source_values = [_]f32{ 1, 2, 3, 4 };
    const records = [_]WriteRecord{
        .{
            .key = .{ .layer_idx = 1, .kind = .mlp_gate },
            .encoding = .raw_f32,
            .packed_layout = .none,
            .group_size = 0,
            .out_f = 1,
            .in_f = source_values.len,
            .num_elements = source_values.len,
            .raw = std.mem.sliceAsBytes(&source_values),
        },
        .{
            .key = .{ .layer_idx = 1, .kind = .mlp_gate },
            .role = .mlp_gate_up_pair,
            .encoding = .pair_nibble,
            .packed_layout = .none,
            .pair_nibble_layout = .rows4_k16,
            .group_size = 8,
            .out_f = 4,
            .in_f = 16,
            .num_elements = 64,
            .packed_bytes = &pair_bytes,
            .scales_f16_rows4 = std.mem.sliceAsBytes(&pair_scales),
        },
    };
    try writeAtomicAt(testing.allocator, tmp.dir, "pair.glrt", .{
        .config = testConfig(),
        .source_fingerprint = fingerprint("pair-source"),
        .sync = false,
    }, &records);

    var image = try MappedImage.openAt(tmp.dir, "pair.glrt");
    defer image.close();
    const source = image.find(1, .mlp_gate) orelse return error.MissingRecord;
    try testing.expectEqual(Role.tensor, source.role);
    try testing.expectEqualSlices(f32, &source_values, try image.f32View(source, .raw));
    const record = image.findRole(1, .mlp_gate_up_pair) orelse
        return error.MissingRecord;
    try testing.expectEqual(fmt.TensorKind.mlp_gate, record.key.kind);
    try testing.expectEqual(Encoding.pair_nibble, record.encoding);
    try testing.expectEqual(PackedLayout.none, record.packed_layout);
    try testing.expectEqual(PairNibbleLayout.rows4_k16, record.pair_nibble_layout);
    const pair = try image.pairNibbleSlices(record);
    try testing.expectEqualSlices(u8, &pair_bytes, pair.packed_pairs);
    try testing.expectEqualSlices(f16, &pair_scales, pair.scales_f16_rows4);
}

test "PairNibble descriptor forbids malformed shape and irrelevant streams" {
    const digest = fingerprint("pair-descriptor-digest");
    const base: Record = .{
        .key = .{ .layer_idx = 0, .kind = .other },
        .role = .mlp_gate_up_pair,
        .encoding = .pair_nibble,
        .packed_layout = .none,
        .pair_nibble_layout = .rows4_k16,
        .group_size = 8,
        .out_f = 4,
        .in_f = 16,
        .num_elements = 64,
        .packed_bytes = .{ .offset = 512, .len = 64 },
        .scales_f16_rows4 = .{ .offset = 576, .len = 32 },
        .payload_crc32 = 0,
        .payload_digest = digest,
    };
    try base.validateBounds(512, 608, 64);

    var bad_payload = base;
    bad_payload.packed_bytes.len -= 1;
    try testing.expectError(
        error.BadTensorShape,
        bad_payload.validateBounds(512, 608, 64),
    );

    var bad_scales = base;
    bad_scales.scales_f16_rows4.len -= @sizeOf(f16);
    try testing.expectError(
        error.BadTensorShape,
        bad_scales.validateBounds(512, 608, 64),
    );

    var bad_group = base;
    bad_group.group_size = 4;
    try testing.expectError(
        error.BadTensorShape,
        bad_group.validateBounds(512, 608, 64),
    );

    var irrelevant = base;
    irrelevant.scales_f16 = .{ .offset = 640, .len = 16 };
    try testing.expectError(
        error.BadEncoding,
        irrelevant.validateBounds(512, 704, 64),
    );

    var wrong_role = base;
    wrong_role.role = .tensor;
    try testing.expectError(error.BadRole, wrong_role.validateBounds(512, 608, 64));

    var wrong_layout = base;
    wrong_layout.pair_nibble_layout = .none;
    try testing.expectError(
        error.BadPairNibbleLayout,
        wrong_layout.validateBounds(512, 608, 64),
    );
}

test "open rejects payload corruption and source fingerprint mismatch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const values = [_]f32{ 1, 2, 3, 4 };
    const records = [_]WriteRecord{.{
        .key = .{ .layer_idx = 0, .kind = .final_norm },
        .encoding = .raw_f32,
        .packed_layout = .none,
        .group_size = 0,
        .out_f = 1,
        .in_f = values.len,
        .num_elements = values.len,
        .raw = std.mem.sliceAsBytes(&values),
    }};
    const source_fingerprint = fingerprint("source-a");
    try writeAtomicAt(testing.allocator, tmp.dir, "model.glrt", .{
        .config = testConfig(),
        .source_fingerprint = source_fingerprint,
        .sync = false,
    }, &records);

    try testing.expectError(
        error.SourceFingerprintMismatch,
        MappedImage.openWithOptionsAt(tmp.dir, "model.glrt", .{
            .expected_source_fingerprint = fingerprint("source-b"),
        }),
    );

    var wrong_abi = ABI_FINGERPRINT;
    wrong_abi[0] ^= 0xff;
    try testing.expectError(
        error.AbiFingerprintMismatch,
        MappedImage.openWithOptionsAt(tmp.dir, "model.glrt", .{
            .expected_abi_fingerprint = wrong_abi,
        }),
    );

    var image = try MappedImage.openWithOptionsAt(tmp.dir, "model.glrt", .{
        .verify_payload_crc = false,
    });
    const record = image.find(0, .final_norm).?;
    const corrupt_at = record.raw.offset;
    image.close();
    const file = try tmp.dir.openFile("model.glrt", .{ .mode = .read_write });
    defer file.close();
    _ = try file.pwrite(&[_]u8{0xff}, corrupt_at);
    try testing.expectError(
        error.DigestMismatch,
        MappedImage.openWithOptionsAt(tmp.dir, "model.glrt", .{
            .verify_payload_crc = false,
        }),
    );
    try testing.expectError(
        error.CrcMismatch,
        MappedImage.openAt(tmp.dir, "model.glrt"),
    );
}

test "v2 digest binds descriptor and fails closed when stored digest changes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const values = [_]f32{ 1, 2, 3, 4 };
    const records = [_]WriteRecord{.{
        .key = .{ .layer_idx = 0, .kind = .final_norm },
        .encoding = .raw_f32,
        .packed_layout = .none,
        .group_size = 0,
        .out_f = 1,
        .in_f = values.len,
        .num_elements = values.len,
        .raw = std.mem.sliceAsBytes(&values),
    }};
    const options: WriteOptions = .{
        .config = testConfig(),
        .source_fingerprint = fingerprint("digest-source"),
        .sync = false,
    };
    try writeAtomicAt(testing.allocator, tmp.dir, "descriptor.glrt", options, &records);
    try writeAtomicAt(testing.allocator, tmp.dir, "digest.glrt", options, &records);

    // Change TensorKind to another valid value and repair both CRC layers.
    // The payload CRC still matches, so only descriptor+payload SHA catches it.
    {
        const file = try tmp.dir.openFile("descriptor.glrt", .{ .mode = .read_write });
        defer file.close();
        var kind_bytes: [4]u8 = undefined;
        putInt(u32, &kind_bytes, @intFromEnum(fmt.TensorKind.input_norm));
        if (try file.pwrite(&kind_bytes, HEADER_SIZE + 4) != kind_bytes.len)
            return error.ShortWrite;
    }
    try repairSingleV2IndexAndHeaderCrc(tmp.dir, "descriptor.glrt");
    try testing.expectError(
        error.DigestMismatch,
        MappedImage.openAt(tmp.dir, "descriptor.glrt"),
    );

    // Corrupt only the stored digest and repair the index/header CRCs.
    {
        const file = try tmp.dir.openFile("digest.glrt", .{ .mode = .read_write });
        defer file.close();
        var byte: [1]u8 = undefined;
        if (try file.preadAll(&byte, HEADER_SIZE + V2_DIGEST_OFFSET) != 1)
            return error.TruncatedIndex;
        byte[0] ^= 0xff;
        if (try file.pwrite(&byte, HEADER_SIZE + V2_DIGEST_OFFSET) != 1)
            return error.ShortWrite;
    }
    try repairSingleV2IndexAndHeaderCrc(tmp.dir, "digest.glrt");
    try testing.expectError(
        error.DigestMismatch,
        MappedImage.openAt(tmp.dir, "digest.glrt"),
    );
}

test "record validation rejects misalignment, bounds overflow, and overlap" {
    const base: Record = .{
        .key = .{ .layer_idx = 0, .kind = .final_norm },
        .encoding = .raw_f32,
        .packed_layout = .none,
        .group_size = 0,
        .out_f = 1,
        .in_f = 4,
        .num_elements = 4,
        .raw = .{ .offset = 513, .len = 16 },
        .payload_crc32 = 0,
        .payload_digest = fingerprint("bounds-digest"),
    };
    try testing.expectError(error.BadAlignment, base.validateBounds(512, 1024, 64));

    var outside = base;
    outside.raw.offset = 1024;
    try testing.expectError(error.BadBounds, outside.validateBounds(512, 1032, 64));

    var overlap: Record = .{
        .key = .{ .layer_idx = 0, .kind = .attn_q },
        .encoding = .int4,
        .packed_layout = .row_major,
        .group_size = 16,
        .out_f = 1,
        .in_f = 16,
        .num_elements = 16,
        .packed_bytes = .{ .offset = 512, .len = 8 },
        .scales_f32 = .{ .offset = 512, .len = 4 },
        .payload_crc32 = 0,
        .payload_digest = fingerprint("overlap-digest"),
    };
    try testing.expectError(error.OverlappingPayload, overlap.validateBounds(512, 1024, 64));
}

test "execution ABI separates AArch64 rows4 and portable layouts" {
    const arm = abiFingerprintFor(.aarch64);
    const portable = abiFingerprintFor(.x86_64);
    try testing.expect(!std.mem.eql(u8, &arm, &portable));
    try testing.expectEqualDeep(abiFingerprintFor(builtin.cpu.arch), ABI_FINGERPRINT);
    try testing.expect(!std.mem.eql(u8, &ABI_FINGERPRINT_V1, &ABI_FINGERPRINT));
    try testing.expectEqualDeep(
        abiFingerprintForVersion(builtin.cpu.arch, .v1),
        ABI_FINGERPRINT_V1,
    );
}

test "fixed ABI rejects record flags and reserved bytes" {
    var record: Record = .{
        .key = .{ .layer_idx = 0, .kind = .final_norm },
        .encoding = .raw_f32,
        .packed_layout = .none,
        .group_size = 0,
        .out_f = 1,
        .in_f = 4,
        .num_elements = 4,
        .raw = .{ .offset = 512, .len = 16 },
        .payload_crc32 = 0,
        .payload_digest = fingerprint("record-digest"),
    };
    record.flags = 1;
    try testing.expectError(error.BadFlags, record.validateBounds(512, 1024, 64));

    record.flags = 0;
    var encoded_record = record.encode(.v2);
    encoded_record[124] = 1;
    try testing.expectError(error.BadReservedField, Record.decode(&encoded_record, .v2));

    var bad_role = record.encode(.v2);
    putInt(u16, bad_role[V2_ROLE_OFFSET..][0..2], 0x7fff);
    try testing.expectError(error.BadRole, Record.decode(&bad_role, .v2));

    var bad_pair_layout = record.encode(.v2);
    putInt(u16, bad_pair_layout[V2_PAIR_LAYOUT_OFFSET..][0..2], 0x7fff);
    try testing.expectError(
        error.BadPairNibbleLayout,
        Record.decode(&bad_pair_layout, .v2),
    );

    var v1_reserved = record.encode(.v1);
    v1_reserved[V1_RECORD_SIZE - 1] = 1;
    try testing.expectError(
        error.BadReservedField,
        Record.decode(v1_reserved[0..V1_RECORD_SIZE], .v1),
    );

    const header: Header = .{
        .record_count = 1,
        .data_offset = 640,
        .file_size = 1024,
        .source_fingerprint = fingerprint("source"),
        .config = testConfig(),
        .index_crc32 = 0,
        .header_crc32 = 0,
    };
    var encoded_header = header.encode();
    encoded_header[HEADER_SIZE - 1] = 1;
    try testing.expectError(error.BadReservedField, Header.decode(&encoded_header));

    var bad_version = header.encode();
    putInt(u16, bad_version[4..6], 3);
    try testing.expectError(error.BadVersion, Header.decode(&bad_version));

    var mismatched_record_size = header.encode();
    putInt(u16, mismatched_record_size[8..10], V1_RECORD_SIZE);
    try testing.expectError(
        error.BadRecordSize,
        Header.decode(&mismatched_record_size),
    );
}
