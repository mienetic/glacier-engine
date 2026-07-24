//! Allocation-free canonical RIFF/WAVE PCM delivery profile.
//!
//! The accepted profile is intentionally narrow: one or two interleaved
//! signed 16-bit little-endian channels, a fixed 44-byte header, and no
//! ancillary chunks or trailing bytes.

const std = @import("std");

pub const Digest = [32]u8;
pub const wave_encoding_abi: u64 = 0x474d_5741_5645_0001;
pub const wave_contract_identity =
    "microsoft-riff-wave;pcm-format1;s16le-interleaved;" ++
    "channels1-or2;fixed-fmt16;fixed-header44;" ++
    "single-data-chunk;no-padding-no-extra-chunks-no-rf64";
pub const maximum_frames: u64 = 4_096;
pub const maximum_channels: u64 = 2;
pub const maximum_sample_rate: u64 = 768_000;
pub const bytes_per_sample: u64 = 2;
pub const header_bytes: usize = 44;

const format_contract_domain =
    "glacier-generated-media-format-contract-v1\x00";
const pcm_format_tag: u16 = 1;
const bits_per_sample: u16 = 16;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const AudioSpecV1 = struct {
    sample_rate: u64,
    channels: u64,
    bytes_per_sample: u64 = bytes_per_sample,
    frame_count: u64,
};

pub const WaveSpecV1 = struct {
    sample_rate: u64,
    channels: u64,
    bytes_per_sample: u64,
    frame_count: u64,
    raw_bytes: u64,
    raw_sha256: Digest,
};

pub const WaveInspectionV1 = struct {
    sample_rate: u64,
    channels: u64,
    bytes_per_sample: u64,
    frame_count: u64,
    raw_bytes: u64,
    raw_sha256: Digest,
};

pub const Error = error{
    InvalidSpec,
    UnsupportedProfile,
    InvalidFormat,
    InvalidPayload,
    InvalidBinding,
    BufferTooSmall,
    BufferAlias,
    ArithmeticOverflow,
};

const PreparedWave = struct {
    channels: u16,
    sample_rate: u32,
    byte_rate: u32,
    block_align: u16,
    raw_bytes: usize,
    riff_bytes: u32,
    required_bytes: usize,
};

pub fn waveFormatContractSha256V1() Digest {
    var hash = Sha256.init(.{});
    hash.update(format_contract_domain);
    var abi_bytes: [8]u8 = undefined;
    std.mem.writeInt(
        u64,
        &abi_bytes,
        wave_encoding_abi,
        .little,
    );
    hash.update(&abi_bytes);
    hash.update(wave_contract_identity);
    var output: Digest = undefined;
    hash.final(&output);
    return output;
}

pub fn requiredWaveBytesV1(
    spec: AudioSpecV1,
    raw_bytes: usize,
) Error!usize {
    return (try prepareWave(spec, raw_bytes)).required_bytes;
}

pub fn encodeWaveV1(
    spec: AudioSpecV1,
    raw_pcm: []const u8,
    destination: []u8,
) Error![]const u8 {
    const prepared = try prepareWave(spec, raw_pcm.len);
    if (destination.len < prepared.required_bytes)
        return Error.BufferTooSmall;
    const output = destination[0..prepared.required_bytes];
    if (slicesOverlap(raw_pcm, output)) return Error.BufferAlias;

    @memcpy(output[0..4], "RIFF");
    writeU32Le(output, 4, prepared.riff_bytes);
    @memcpy(output[8..12], "WAVE");
    @memcpy(output[12..16], "fmt ");
    writeU32Le(output, 16, 16);
    writeU16Le(output, 20, pcm_format_tag);
    writeU16Le(output, 22, prepared.channels);
    writeU32Le(output, 24, prepared.sample_rate);
    writeU32Le(output, 28, prepared.byte_rate);
    writeU16Le(output, 32, prepared.block_align);
    writeU16Le(output, 34, bits_per_sample);
    @memcpy(output[36..40], "data");
    writeU32Le(output, 40, @intCast(prepared.raw_bytes));
    @memcpy(output[header_bytes..], raw_pcm);
    return output;
}

pub fn inspectWaveV1(encoded: []const u8) Error!WaveInspectionV1 {
    if (encoded.len < header_bytes or
        !std.mem.eql(u8, encoded[0..4], "RIFF") or
        !std.mem.eql(u8, encoded[8..12], "WAVE") or
        !std.mem.eql(u8, encoded[12..16], "fmt ") or
        readU32Le(encoded, 16) != 16 or
        readU16Le(encoded, 20) != pcm_format_tag or
        !std.mem.eql(u8, encoded[36..40], "data"))
        return Error.InvalidFormat;

    const riff_bytes: usize = readU32Le(encoded, 4);
    const expected_file_bytes = std.math.add(
        usize,
        riff_bytes,
        8,
    ) catch return Error.InvalidFormat;
    if (expected_file_bytes != encoded.len)
        return Error.InvalidFormat;

    const channels = readU16Le(encoded, 22);
    const sample_rate = readU32Le(encoded, 24);
    const byte_rate = readU32Le(encoded, 28);
    const block_align = readU16Le(encoded, 32);
    const sample_bits = readU16Le(encoded, 34);
    const raw_bytes: usize = readU32Le(encoded, 40);
    const expected_raw_end = std.math.add(
        usize,
        header_bytes,
        raw_bytes,
    ) catch return Error.InvalidFormat;
    if (expected_raw_end != encoded.len or
        channels == 0 or
        channels > maximum_channels or
        sample_rate == 0 or
        sample_rate > maximum_sample_rate or
        sample_bits != bits_per_sample)
        return Error.InvalidFormat;

    const expected_block_align_u64 = std.math.mul(
        u64,
        channels,
        bytes_per_sample,
    ) catch return Error.InvalidFormat;
    const expected_byte_rate_u64 = std.math.mul(
        u64,
        sample_rate,
        expected_block_align_u64,
    ) catch return Error.InvalidFormat;
    if (expected_block_align_u64 != block_align or
        expected_byte_rate_u64 != byte_rate or
        block_align == 0 or
        raw_bytes == 0 or
        raw_bytes % block_align != 0)
        return Error.InvalidFormat;
    const frame_count = raw_bytes / block_align;
    if (frame_count == 0 or frame_count > maximum_frames)
        return Error.InvalidFormat;

    const raw = encoded[header_bytes..];
    return .{
        .sample_rate = sample_rate,
        .channels = channels,
        .bytes_per_sample = bytes_per_sample,
        .frame_count = frame_count,
        .raw_bytes = raw_bytes,
        .raw_sha256 = sha256(raw),
    };
}

pub fn validateWaveV1(
    encoded: []const u8,
    spec: WaveSpecV1,
) Error!void {
    const audio_spec = AudioSpecV1{
        .sample_rate = spec.sample_rate,
        .channels = spec.channels,
        .bytes_per_sample = spec.bytes_per_sample,
        .frame_count = spec.frame_count,
    };
    _ = try prepareWave(
        audio_spec,
        std.math.cast(usize, spec.raw_bytes) orelse
            return Error.ArithmeticOverflow,
    );
    const inspected = try inspectWaveV1(encoded);
    if (inspected.sample_rate != spec.sample_rate or
        inspected.channels != spec.channels or
        inspected.bytes_per_sample != spec.bytes_per_sample or
        inspected.frame_count != spec.frame_count or
        inspected.raw_bytes != spec.raw_bytes or
        !digestEqual(inspected.raw_sha256, spec.raw_sha256))
        return Error.InvalidBinding;
}

fn prepareWave(
    spec: AudioSpecV1,
    raw_bytes: usize,
) Error!PreparedWave {
    if (spec.sample_rate == 0 or
        spec.sample_rate > maximum_sample_rate or
        spec.channels == 0 or
        spec.frame_count == 0 or
        spec.frame_count > maximum_frames)
        return Error.InvalidSpec;
    if (spec.channels > maximum_channels or
        spec.bytes_per_sample != bytes_per_sample)
        return Error.UnsupportedProfile;

    const expected_samples = std.math.mul(
        u64,
        spec.frame_count,
        spec.channels,
    ) catch return Error.ArithmeticOverflow;
    const expected_raw_u64 = std.math.mul(
        u64,
        expected_samples,
        spec.bytes_per_sample,
    ) catch return Error.ArithmeticOverflow;
    const expected_raw = std.math.cast(
        usize,
        expected_raw_u64,
    ) orelse return Error.ArithmeticOverflow;
    if (raw_bytes != expected_raw) return Error.InvalidPayload;

    const block_align_u64 = std.math.mul(
        u64,
        spec.channels,
        spec.bytes_per_sample,
    ) catch return Error.ArithmeticOverflow;
    const byte_rate_u64 = std.math.mul(
        u64,
        spec.sample_rate,
        block_align_u64,
    ) catch return Error.ArithmeticOverflow;
    const required = std.math.add(
        usize,
        header_bytes,
        raw_bytes,
    ) catch return Error.ArithmeticOverflow;
    const riff_bytes = required - 8;
    if (spec.channels > std.math.maxInt(u16) or
        spec.sample_rate > std.math.maxInt(u32) or
        block_align_u64 > std.math.maxInt(u16) or
        byte_rate_u64 > std.math.maxInt(u32) or
        raw_bytes > std.math.maxInt(u32) or
        riff_bytes > std.math.maxInt(u32))
        return Error.ArithmeticOverflow;
    return .{
        .channels = @intCast(spec.channels),
        .sample_rate = @intCast(spec.sample_rate),
        .byte_rate = @intCast(byte_rate_u64),
        .block_align = @intCast(block_align_u64),
        .raw_bytes = raw_bytes,
        .riff_bytes = @intCast(riff_bytes),
        .required_bytes = required,
    };
}

fn slicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(usize, a_start, a.len) catch
        return true;
    const b_end = std.math.add(usize, b_start, b.len) catch
        return true;
    return a_start < b_end and b_start < a_end;
}

fn digestEqual(a: Digest, b: Digest) bool {
    return std.mem.eql(u8, &a, &b);
}

fn sha256(bytes: []const u8) Digest {
    var output: Digest = undefined;
    Sha256.hash(bytes, &output, .{});
    return output;
}

fn writeU16Le(output: []u8, offset: usize, value: u16) void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    @memcpy(output[offset .. offset + 2], &bytes);
}

fn writeU32Le(output: []u8, offset: usize, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    @memcpy(output[offset .. offset + 4], &bytes);
}

fn readU16Le(input: []const u8, offset: usize) u16 {
    return std.mem.readInt(
        u16,
        input[offset .. offset + 2][0..2],
        .little,
    );
}

fn readU32Le(input: []const u8, offset: usize) u32 {
    return std.mem.readInt(
        u32,
        input[offset .. offset + 4][0..4],
        .little,
    );
}

fn digestFromHex(hex: []const u8) !Digest {
    var output: Digest = undefined;
    _ = try std.fmt.hexToBytes(&output, hex);
    return output;
}

fn waveBindingSpec(
    spec: AudioSpecV1,
    raw: []const u8,
) WaveSpecV1 {
    return .{
        .sample_rate = spec.sample_rate,
        .channels = spec.channels,
        .bytes_per_sample = spec.bytes_per_sample,
        .frame_count = spec.frame_count,
        .raw_bytes = raw.len,
        .raw_sha256 = sha256(raw),
    };
}

test "canonical mono PCM WAVE matches the independent vector" {
    const spec = AudioSpecV1{
        .sample_rate = 16_000,
        .channels = 1,
        .frame_count = 2,
    };
    const raw = [_]u8{ 0x00, 0x01, 0x00, 0xff };
    var destination: [48]u8 = undefined;
    const encoded = try encodeWaveV1(spec, &raw, &destination);
    try std.testing.expectEqual(@as(usize, 48), encoded.len);
    var expected: [48]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &expected,
        "524946462800000057415645666d74201000000001000100803e0000007d00000200" ++
            "10006461746104000000000100ff",
    );
    try std.testing.expectEqualSlices(u8, &expected, encoded);
    try std.testing.expectEqualDeep(
        try digestFromHex(
            "e38a9a172dae97f9a9dacd5fe7644124521681eba57afb75a31613f21865955d",
        ),
        sha256(encoded),
    );
    const inspected = try inspectWaveV1(encoded);
    try std.testing.expectEqual(spec.sample_rate, inspected.sample_rate);
    try std.testing.expectEqual(spec.channels, inspected.channels);
    try std.testing.expectEqual(spec.frame_count, inspected.frame_count);
    try std.testing.expectEqualDeep(
        sha256(&raw),
        inspected.raw_sha256,
    );
    try validateWaveV1(
        encoded,
        waveBindingSpec(spec, &raw),
    );
}

test "WAVE accepts canonical mono and stereo limits" {
    const cases = [_]AudioSpecV1{
        .{
            .sample_rate = 8_000,
            .channels = 1,
            .frame_count = 1,
        },
        .{
            .sample_rate = maximum_sample_rate,
            .channels = 2,
            .frame_count = maximum_frames,
        },
    };
    const allocator = std.testing.allocator;
    for (cases) |spec| {
        const raw_bytes: usize = @intCast(
            spec.frame_count * spec.channels * bytes_per_sample,
        );
        const required = try requiredWaveBytesV1(spec, raw_bytes);
        const raw = try allocator.alloc(u8, raw_bytes);
        defer allocator.free(raw);
        const destination = try allocator.alloc(u8, required);
        defer allocator.free(destination);
        for (raw, 0..) |*value, index|
            value.* = @truncate(index);
        const encoded = try encodeWaveV1(
            spec,
            raw,
            destination,
        );
        try validateWaveV1(
            encoded,
            waveBindingSpec(spec, raw),
        );
    }
}

test "WAVE binding rejects every encoded-byte mutation" {
    const spec = AudioSpecV1{
        .sample_rate = 16_000,
        .channels = 1,
        .frame_count = 2,
    };
    const raw = [_]u8{ 0x00, 0x01, 0x00, 0xff };
    var canonical: [48]u8 = undefined;
    _ = try encodeWaveV1(spec, &raw, &canonical);
    const binding = waveBindingSpec(spec, &raw);
    for (0..canonical.len) |index| {
        var mutated = canonical;
        mutated[index] ^= 1;
        if (validateWaveV1(&mutated, binding)) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "WAVE rejects extra chunks and semantic contradictions" {
    const spec = AudioSpecV1{
        .sample_rate = 16_000,
        .channels = 1,
        .frame_count = 2,
    };
    const raw = [_]u8{ 0x00, 0x01, 0x00, 0xff };
    var canonical: [48]u8 = undefined;
    _ = try encodeWaveV1(spec, &raw, &canonical);

    var trailing: [49]u8 = undefined;
    @memcpy(trailing[0..48], &canonical);
    trailing[48] = 0;
    try std.testing.expectError(
        Error.InvalidFormat,
        inspectWaveV1(&trailing),
    );

    var wrong_rate = canonical;
    writeU32Le(&wrong_rate, 24, 8_000);
    try std.testing.expectError(
        Error.InvalidFormat,
        inspectWaveV1(&wrong_rate),
    );

    const foreign_raw = [_]u8{ 0, 1, 0, 1 };
    var foreign: [48]u8 = undefined;
    _ = try encodeWaveV1(spec, &foreign_raw, &foreign);
    try std.testing.expectError(
        Error.InvalidBinding,
        validateWaveV1(
            &foreign,
            waveBindingSpec(spec, &raw),
        ),
    );
}

test "WAVE preflight failures leave destination unchanged" {
    const spec = AudioSpecV1{
        .sample_rate = 16_000,
        .channels = 1,
        .frame_count = 2,
    };
    const raw = [_]u8{ 0x00, 0x01, 0x00, 0xff };
    var short = [_]u8{0xa5} ** 47;
    try std.testing.expectError(
        Error.BufferTooSmall,
        encodeWaveV1(spec, &raw, &short),
    );
    try std.testing.expect(std.mem.allEqual(u8, &short, 0xa5));

    var wrong = [_]u8{0xa5} ** 48;
    try std.testing.expectError(
        Error.InvalidPayload,
        encodeWaveV1(spec, raw[0..3], &wrong),
    );
    try std.testing.expect(std.mem.allEqual(u8, &wrong, 0xa5));

    var alias = [_]u8{0xa5} ** 48;
    try std.testing.expectError(
        Error.BufferAlias,
        encodeWaveV1(spec, alias[0..4], &alias),
    );
    try std.testing.expect(std.mem.allEqual(u8, &alias, 0xa5));

    const unsupported = AudioSpecV1{
        .sample_rate = 16_000,
        .channels = 3,
        .frame_count = 2,
    };
    try std.testing.expectError(
        Error.UnsupportedProfile,
        encodeWaveV1(unsupported, alias[0..12], &alias),
    );
    try std.testing.expect(std.mem.allEqual(u8, &alias, 0xa5));
}

test "WAVE format contract root is stable" {
    try std.testing.expectEqualDeep(
        try digestFromHex(
            "47919dc5fdc5024a1834132048f063cc9fed163e346c2b9572368c8b7f4544c8",
        ),
        waveFormatContractSha256V1(),
    );
}
