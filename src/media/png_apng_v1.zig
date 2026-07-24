//! Allocation-free canonical PNG/APNG delivery profiles.
//!
//! This module deliberately accepts only the byte-exact subset that it emits.
//! It is not a general PNG or APNG decoder.

const std = @import("std");

pub const Digest = [32]u8;

pub const png_signature = [_]u8{
    0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a,
};
pub const maximum_png_dimension: u64 = 8_192;
pub const maximum_png_raw_bytes: u64 = 16 * 1024 * 1024;
pub const maximum_apng_dimension: u64 = 4_096;
pub const maximum_apng_raw_bytes: u64 = 256 * 1024 * 1024;
pub const apng_frame_count: u64 = 2;
pub const stored_block_bytes: usize = 65_535;
pub const png_encoding_abi: u64 = 0x474d_504e_4700_0001;
pub const apng_encoding_abi: u64 = 0x474d_4150_4e47_0001;
pub const png_contract_identity =
    "w3c-png-3;png8;gray-gray-alpha-rgb-rgba;" ++
    "linear-gama100000-or-srgb-intent0;filter0;" ++
    "zlib-7801-stored-max65535;one-idat;no-extra-chunks";
pub const apng_contract_identity =
    "w3c-png-3;apng-gray8-two-full-canvas-frames;" ++
    "linear-gama100000;plays1;source-blend;dispose-none;" ++
    "reduced-exact-u16-delays;per-frame-zlib-7801-stored-max65535;" ++
    "one-idat-one-fdat;no-extra-chunks";

const png_bit_depth: u8 = 8;
const zlib_cmf: u8 = 0x78;
const zlib_flg: u8 = 0x01;
const gamma_linear: u32 = 100_000;
const format_contract_domain =
    "glacier-generated-media-format-contract-v1\x00";

pub const ColorModelV1 = enum(u8) {
    gray = 1,
    rgb = 2,
};

pub const TransferFunctionV1 = enum(u8) {
    linear = 1,
    srgb = 2,
};

pub const AlphaModeV1 = enum(u8) {
    none = 1,
    straight = 2,
};

pub const ImageSpecV1 = struct {
    width: u64,
    height: u64,
    channels: u64,
    color_model: ColorModelV1,
    transfer_function: TransferFunctionV1,
    alpha_mode: AlphaModeV1,
};

pub const AnimationSpecV1 = struct {
    width: u64,
    height: u64,
    channels: u64 = 1,
    bytes_per_channel: u64 = 1,
    frame_count: u64 = apng_frame_count,
    time_base_numerator: u64,
    time_base_denominator: u64,
    first_duration_ticks: u64,
    second_duration_ticks: u64,
};

pub const PngSpecV1 = struct {
    width: u64,
    height: u64,
    channels: u64,
    transfer_function: TransferFunctionV1,
    alpha_mode: AlphaModeV1,
    raw_bytes: u64,
    raw_sha256: Digest,
};

pub const ApngSpecV1 = struct {
    width: u64,
    height: u64,
    channels: u64,
    bytes_per_channel: u64,
    frame_count: u64,
    time_base_numerator: u64,
    time_base_denominator: u64,
    first_duration_ticks: u64,
    second_duration_ticks: u64,
    frame_bytes: u64,
    raw_bytes: u64,
    frame_sha256: [2]Digest,
    raw_sha256: Digest,
};

pub const PngInspectionV1 = struct {
    width: u64,
    height: u64,
    channels: u64,
    color_model: ColorModelV1,
    transfer_function: TransferFunctionV1,
    alpha_mode: AlphaModeV1,
    raw_bytes: u64,
    raw_sha256: Digest,
};

pub const ApngInspectionV1 = struct {
    width: u64,
    height: u64,
    channels: u64,
    bytes_per_channel: u64,
    frame_count: u64,
    frame_bytes: u64,
    delay_numerators: [2]u16,
    delay_denominators: [2]u16,
    raw_bytes: u64,
    frame_sha256: [2]Digest,
    raw_sha256: Digest,
};

pub const Error = error{
    InvalidSpec,
    UnsupportedProfile,
    UnsupportedTiming,
    InvalidFormat,
    InvalidChecksum,
    InvalidPayload,
    InvalidBinding,
    BufferTooSmall,
    BufferAlias,
    ArithmeticOverflow,
};

const RasterLayout = struct {
    width: usize,
    height: usize,
    channels: usize,
    row_bytes: usize,
    raw_bytes: usize,
    filtered_bytes: usize,
    zlib_bytes: usize,
};

const PreparedPng = struct {
    layout: RasterLayout,
    color_type: u8,
    required_bytes: usize,
};

const DelayFraction = struct {
    numerator: u16,
    denominator: u16,
};

const PreparedApng = struct {
    layout: RasterLayout,
    raw_bytes: usize,
    first_delay: DelayFraction,
    second_delay: DelayFraction,
    required_bytes: usize,
};

const RawInspection = struct {
    raw_bytes: usize,
    raw_sha256: Digest,
};

const Chunk = struct {
    kind: [4]u8,
    data: []const u8,
};

const OpenChunk = struct {
    type_offset: usize,
    data: []u8,
    crc_offset: usize,
};

const Sha256 = std.crypto.hash.sha2.Sha256;

pub fn pngFormatContractSha256V1() Digest {
    return formatContractRoot(
        png_encoding_abi,
        png_contract_identity,
    );
}

pub fn apngFormatContractSha256V1() Digest {
    return formatContractRoot(
        apng_encoding_abi,
        apng_contract_identity,
    );
}

pub fn requiredPngBytesV1(
    spec: ImageSpecV1,
    raw_bytes: usize,
) Error!usize {
    return (try preparePng(spec, raw_bytes)).required_bytes;
}

pub fn encodePngV1(
    spec: ImageSpecV1,
    raw: []const u8,
    destination: []u8,
) Error![]const u8 {
    const prepared = try preparePng(spec, raw.len);
    if (destination.len < prepared.required_bytes)
        return Error.BufferTooSmall;
    const output = destination[0..prepared.required_bytes];
    if (slicesOverlap(raw, output)) return Error.BufferAlias;

    var cursor: usize = 0;
    @memcpy(output[cursor .. cursor + png_signature.len], &png_signature);
    cursor += png_signature.len;

    var ihdr = [_]u8{0} ** 13;
    writeU32Be(&ihdr, 0, @intCast(spec.width));
    writeU32Be(&ihdr, 4, @intCast(spec.height));
    ihdr[8] = png_bit_depth;
    ihdr[9] = prepared.color_type;
    writeChunk(output, &cursor, "IHDR".*, &ihdr);

    switch (spec.transfer_function) {
        .linear => {
            var gamma: [4]u8 = undefined;
            writeU32Be(&gamma, 0, gamma_linear);
            writeChunk(output, &cursor, "gAMA".*, &gamma);
        },
        .srgb => {
            const intent = [_]u8{0};
            writeChunk(output, &cursor, "sRGB".*, &intent);
        },
    }

    const idat = openChunk(
        output,
        &cursor,
        "IDAT".*,
        prepared.layout.zlib_bytes,
    );
    writeStoredZlib(
        idat.data,
        raw,
        prepared.layout.row_bytes,
        prepared.layout.height,
    );
    sealChunk(output, idat);

    writeChunk(output, &cursor, "IEND".*, &.{});
    std.debug.assert(cursor == output.len);
    return output;
}

pub fn inspectPngV1(encoded: []const u8) Error!PngInspectionV1 {
    var cursor = try consumeSignature(encoded);
    const ihdr = try takeExpectedChunk(
        encoded,
        &cursor,
        "IHDR".*,
        13,
    );
    const width = readU32Be(ihdr, 0);
    const height = readU32Be(ihdr, 4);
    if (ihdr[8] != png_bit_depth or
        ihdr[10] != 0 or
        ihdr[11] != 0 or
        ihdr[12] != 0)
        return Error.InvalidFormat;

    const shape = colorShapeFromPngType(ihdr[9]) catch
        return Error.InvalidFormat;
    const spec_without_transfer = ImageSpecV1{
        .width = width,
        .height = height,
        .channels = shape.channels,
        .color_model = shape.color_model,
        .transfer_function = .linear,
        .alpha_mode = shape.alpha_mode,
    };
    _ = validateImageSpec(spec_without_transfer) catch
        return Error.InvalidFormat;

    const color_chunk = try takeChunk(encoded, &cursor);
    const transfer_function: TransferFunctionV1 =
        if (std.mem.eql(u8, &color_chunk.kind, "gAMA")) blk: {
            if (color_chunk.data.len != 4 or
                readU32Be(color_chunk.data, 0) != gamma_linear)
                return Error.InvalidFormat;
            break :blk .linear;
        } else if (std.mem.eql(u8, &color_chunk.kind, "sRGB")) blk: {
            if (color_chunk.data.len != 1 or
                color_chunk.data[0] != 0)
                return Error.InvalidFormat;
            break :blk .srgb;
        } else return Error.InvalidFormat;

    const spec = ImageSpecV1{
        .width = width,
        .height = height,
        .channels = shape.channels,
        .color_model = shape.color_model,
        .transfer_function = transfer_function,
        .alpha_mode = shape.alpha_mode,
    };
    const layout = try rasterLayout(
        spec.width,
        spec.height,
        spec.channels,
        maximum_png_dimension,
        maximum_png_raw_bytes,
    );
    const idat = try takeExpectedChunk(
        encoded,
        &cursor,
        "IDAT".*,
        layout.zlib_bytes,
    );
    const raw = try inspectStoredZlib(
        idat,
        layout.row_bytes,
        layout.height,
        null,
    );
    _ = try takeExpectedChunk(encoded, &cursor, "IEND".*, 0);
    if (cursor != encoded.len) return Error.InvalidFormat;
    return .{
        .width = spec.width,
        .height = spec.height,
        .channels = spec.channels,
        .color_model = spec.color_model,
        .transfer_function = spec.transfer_function,
        .alpha_mode = spec.alpha_mode,
        .raw_bytes = @intCast(raw.raw_bytes),
        .raw_sha256 = raw.raw_sha256,
    };
}

pub fn validatePngV1(
    encoded: []const u8,
    spec: PngSpecV1,
) Error!void {
    const image_spec = try imageSpecFromPngSpec(spec);
    _ = try preparePng(
        image_spec,
        std.math.cast(usize, spec.raw_bytes) orelse
            return Error.ArithmeticOverflow,
    );
    const inspected = try inspectPngV1(encoded);
    if (inspected.width != image_spec.width or
        inspected.height != image_spec.height or
        inspected.channels != image_spec.channels or
        inspected.color_model != image_spec.color_model or
        inspected.transfer_function !=
            image_spec.transfer_function or
        inspected.alpha_mode != image_spec.alpha_mode or
        inspected.raw_bytes != spec.raw_bytes or
        !digestEqual(inspected.raw_sha256, spec.raw_sha256))
        return Error.InvalidBinding;
}

pub fn requiredApngBytesV1(
    spec: AnimationSpecV1,
    raw_bytes: usize,
) Error!usize {
    return (try prepareApng(spec, raw_bytes)).required_bytes;
}

pub fn encodeApngV1(
    spec: AnimationSpecV1,
    raw_frames: []const u8,
    destination: []u8,
) Error![]const u8 {
    const prepared = try prepareApng(spec, raw_frames.len);
    if (destination.len < prepared.required_bytes)
        return Error.BufferTooSmall;
    const output = destination[0..prepared.required_bytes];
    if (slicesOverlap(raw_frames, output)) return Error.BufferAlias;

    const first_frame = raw_frames[0..prepared.layout.raw_bytes];
    const second_frame =
        raw_frames[prepared.layout.raw_bytes..prepared.raw_bytes];
    var cursor: usize = 0;
    @memcpy(output[cursor .. cursor + png_signature.len], &png_signature);
    cursor += png_signature.len;

    var ihdr = [_]u8{0} ** 13;
    writeU32Be(&ihdr, 0, @intCast(spec.width));
    writeU32Be(&ihdr, 4, @intCast(spec.height));
    ihdr[8] = png_bit_depth;
    ihdr[9] = 0;
    writeChunk(output, &cursor, "IHDR".*, &ihdr);

    var gamma: [4]u8 = undefined;
    writeU32Be(&gamma, 0, gamma_linear);
    writeChunk(output, &cursor, "gAMA".*, &gamma);

    var animation_control: [8]u8 = undefined;
    writeU32Be(&animation_control, 0, 2);
    writeU32Be(&animation_control, 4, 1);
    writeChunk(output, &cursor, "acTL".*, &animation_control);

    var first_control = frameControl(
        0,
        @intCast(spec.width),
        @intCast(spec.height),
        prepared.first_delay,
    );
    writeChunk(output, &cursor, "fcTL".*, &first_control);

    const idat = openChunk(
        output,
        &cursor,
        "IDAT".*,
        prepared.layout.zlib_bytes,
    );
    writeStoredZlib(
        idat.data,
        first_frame,
        prepared.layout.row_bytes,
        prepared.layout.height,
    );
    sealChunk(output, idat);

    var second_control = frameControl(
        1,
        @intCast(spec.width),
        @intCast(spec.height),
        prepared.second_delay,
    );
    writeChunk(output, &cursor, "fcTL".*, &second_control);

    const fdat = openChunk(
        output,
        &cursor,
        "fdAT".*,
        prepared.layout.zlib_bytes + 4,
    );
    writeU32Be(fdat.data, 0, 2);
    writeStoredZlib(
        fdat.data[4..],
        second_frame,
        prepared.layout.row_bytes,
        prepared.layout.height,
    );
    sealChunk(output, fdat);

    writeChunk(output, &cursor, "IEND".*, &.{});
    std.debug.assert(cursor == output.len);
    return output;
}

pub fn inspectApngV1(encoded: []const u8) Error!ApngInspectionV1 {
    var cursor = try consumeSignature(encoded);
    const ihdr = try takeExpectedChunk(
        encoded,
        &cursor,
        "IHDR".*,
        13,
    );
    const width = readU32Be(ihdr, 0);
    const height = readU32Be(ihdr, 4);
    if (ihdr[8] != png_bit_depth or
        ihdr[9] != 0 or
        ihdr[10] != 0 or
        ihdr[11] != 0 or
        ihdr[12] != 0)
        return Error.InvalidFormat;
    const layout = rasterLayout(
        width,
        height,
        1,
        maximum_apng_dimension,
        maximum_apng_raw_bytes / 2,
    ) catch return Error.InvalidFormat;

    const gamma = try takeExpectedChunk(
        encoded,
        &cursor,
        "gAMA".*,
        4,
    );
    if (readU32Be(gamma, 0) != gamma_linear)
        return Error.InvalidFormat;

    const animation_control = try takeExpectedChunk(
        encoded,
        &cursor,
        "acTL".*,
        8,
    );
    if (readU32Be(animation_control, 0) != 2 or
        readU32Be(animation_control, 4) != 1)
        return Error.InvalidFormat;

    const first_control = try takeExpectedChunk(
        encoded,
        &cursor,
        "fcTL".*,
        26,
    );
    const first_delay = try inspectFrameControl(
        first_control,
        0,
        width,
        height,
    );
    const idat = try takeExpectedChunk(
        encoded,
        &cursor,
        "IDAT".*,
        layout.zlib_bytes,
    );

    var aggregate = Sha256.init(.{});
    const first_frame = try inspectStoredZlib(
        idat,
        layout.row_bytes,
        layout.height,
        &aggregate,
    );

    const second_control = try takeExpectedChunk(
        encoded,
        &cursor,
        "fcTL".*,
        26,
    );
    const second_delay = try inspectFrameControl(
        second_control,
        1,
        width,
        height,
    );
    const fdat = try takeExpectedChunk(
        encoded,
        &cursor,
        "fdAT".*,
        layout.zlib_bytes + 4,
    );
    if (readU32Be(fdat, 0) != 2) return Error.InvalidFormat;
    const second_frame = try inspectStoredZlib(
        fdat[4..],
        layout.row_bytes,
        layout.height,
        &aggregate,
    );

    _ = try takeExpectedChunk(encoded, &cursor, "IEND".*, 0);
    if (cursor != encoded.len) return Error.InvalidFormat;
    var raw_sha256: Digest = undefined;
    aggregate.final(&raw_sha256);
    const total_raw = checkedMul(layout.raw_bytes, 2) catch
        return Error.InvalidFormat;
    return .{
        .width = width,
        .height = height,
        .channels = 1,
        .bytes_per_channel = 1,
        .frame_count = 2,
        .frame_bytes = @intCast(layout.raw_bytes),
        .delay_numerators = .{
            first_delay.numerator,
            second_delay.numerator,
        },
        .delay_denominators = .{
            first_delay.denominator,
            second_delay.denominator,
        },
        .raw_bytes = @intCast(total_raw),
        .frame_sha256 = .{
            first_frame.raw_sha256,
            second_frame.raw_sha256,
        },
        .raw_sha256 = raw_sha256,
    };
}

pub fn validateApngV1(
    encoded: []const u8,
    spec: ApngSpecV1,
) Error!void {
    const animation_spec = AnimationSpecV1{
        .width = spec.width,
        .height = spec.height,
        .channels = spec.channels,
        .bytes_per_channel = spec.bytes_per_channel,
        .frame_count = spec.frame_count,
        .time_base_numerator = spec.time_base_numerator,
        .time_base_denominator = spec.time_base_denominator,
        .first_duration_ticks = spec.first_duration_ticks,
        .second_duration_ticks = spec.second_duration_ticks,
    };
    const expected_raw_bytes = std.math.cast(usize, spec.raw_bytes) orelse
        return Error.ArithmeticOverflow;
    const prepared = try prepareApng(
        animation_spec,
        expected_raw_bytes,
    );
    const inspected = try inspectApngV1(encoded);
    if (spec.frame_bytes != prepared.layout.raw_bytes or
        spec.raw_bytes != prepared.raw_bytes or
        inspected.width != animation_spec.width or
        inspected.height != animation_spec.height or
        inspected.channels != animation_spec.channels or
        inspected.bytes_per_channel !=
            animation_spec.bytes_per_channel or
        inspected.frame_count != animation_spec.frame_count or
        inspected.frame_bytes != spec.frame_bytes or
        inspected.raw_bytes != spec.raw_bytes or
        inspected.delay_numerators[0] !=
            prepared.first_delay.numerator or
        inspected.delay_denominators[0] !=
            prepared.first_delay.denominator or
        inspected.delay_numerators[1] !=
            prepared.second_delay.numerator or
        inspected.delay_denominators[1] !=
            prepared.second_delay.denominator or
        !digestEqual(
            inspected.frame_sha256[0],
            spec.frame_sha256[0],
        ) or
        !digestEqual(
            inspected.frame_sha256[1],
            spec.frame_sha256[1],
        ) or
        !digestEqual(inspected.raw_sha256, spec.raw_sha256))
        return Error.InvalidBinding;
}

fn preparePng(
    spec: ImageSpecV1,
    raw_bytes: usize,
) Error!PreparedPng {
    try validateImageSpec(spec);
    const layout = try rasterLayout(
        spec.width,
        spec.height,
        spec.channels,
        maximum_png_dimension,
        maximum_png_raw_bytes,
    );
    if (raw_bytes != layout.raw_bytes) return Error.InvalidPayload;
    const color_type = try pngColorType(spec);
    const color_chunk_bytes: usize = switch (spec.transfer_function) {
        .linear => try chunkBytes(4),
        .srgb => try chunkBytes(1),
    };
    if (layout.zlib_bytes > std.math.maxInt(u32))
        return Error.ArithmeticOverflow;
    var required = png_signature.len;
    required = try checkedAdd(required, try chunkBytes(13));
    required = try checkedAdd(required, color_chunk_bytes);
    required = try checkedAdd(
        required,
        try chunkBytes(layout.zlib_bytes),
    );
    required = try checkedAdd(required, try chunkBytes(0));
    return .{
        .layout = layout,
        .color_type = color_type,
        .required_bytes = required,
    };
}

fn prepareApng(
    spec: AnimationSpecV1,
    raw_bytes: usize,
) Error!PreparedApng {
    try validateAnimationSpec(spec);
    const layout = try rasterLayout(
        spec.width,
        spec.height,
        spec.channels,
        maximum_apng_dimension,
        maximum_apng_raw_bytes / 2,
    );
    const total_raw = try checkedMul(layout.raw_bytes, 2);
    if (total_raw > maximum_apng_raw_bytes)
        return Error.UnsupportedProfile;
    if (raw_bytes != total_raw) return Error.InvalidPayload;
    const first_delay = try delayFraction(
        spec.first_duration_ticks,
        spec.time_base_numerator,
        spec.time_base_denominator,
    );
    const second_delay = try delayFraction(
        spec.second_duration_ticks,
        spec.time_base_numerator,
        spec.time_base_denominator,
    );
    if (layout.zlib_bytes > std.math.maxInt(u32) - 4)
        return Error.ArithmeticOverflow;
    var required = png_signature.len;
    required = try checkedAdd(required, try chunkBytes(13));
    required = try checkedAdd(required, try chunkBytes(4));
    required = try checkedAdd(required, try chunkBytes(8));
    required = try checkedAdd(required, try chunkBytes(26));
    required = try checkedAdd(
        required,
        try chunkBytes(layout.zlib_bytes),
    );
    required = try checkedAdd(required, try chunkBytes(26));
    required = try checkedAdd(
        required,
        try chunkBytes(try checkedAdd(layout.zlib_bytes, 4)),
    );
    required = try checkedAdd(required, try chunkBytes(0));
    return .{
        .layout = layout,
        .raw_bytes = total_raw,
        .first_delay = first_delay,
        .second_delay = second_delay,
        .required_bytes = required,
    };
}

fn validateImageSpec(spec: ImageSpecV1) Error!void {
    if (spec.width == 0 or
        spec.width > maximum_png_dimension or
        spec.height == 0 or
        spec.height > maximum_png_dimension or
        spec.channels == 0 or
        spec.channels > 4)
        return Error.InvalidSpec;
    const valid_shape = switch (spec.channels) {
        1 => spec.color_model == .gray and
            spec.alpha_mode == .none,
        2 => spec.color_model == .gray and
            spec.alpha_mode == .straight,
        3 => spec.color_model == .rgb and
            spec.alpha_mode == .none,
        4 => spec.color_model == .rgb and
            spec.alpha_mode == .straight,
        else => false,
    };
    if (!valid_shape) return Error.UnsupportedProfile;
}

fn imageSpecFromPngSpec(spec: PngSpecV1) Error!ImageSpecV1 {
    const color_model: ColorModelV1 = switch (spec.channels) {
        1, 2 => .gray,
        3, 4 => .rgb,
        else => return Error.UnsupportedProfile,
    };
    const image_spec = ImageSpecV1{
        .width = spec.width,
        .height = spec.height,
        .channels = spec.channels,
        .color_model = color_model,
        .transfer_function = spec.transfer_function,
        .alpha_mode = spec.alpha_mode,
    };
    try validateImageSpec(image_spec);
    return image_spec;
}

fn validateAnimationSpec(spec: AnimationSpecV1) Error!void {
    if (spec.width == 0 or
        spec.width > maximum_apng_dimension or
        spec.height == 0 or
        spec.height > maximum_apng_dimension or
        spec.channels != 1 or
        spec.bytes_per_channel != 1 or
        spec.frame_count != apng_frame_count)
        return Error.UnsupportedProfile;
    if (spec.time_base_numerator == 0 or
        spec.time_base_denominator == 0 or
        spec.first_duration_ticks == 0 or
        spec.second_duration_ticks == 0)
        return Error.InvalidSpec;
}

fn expectedImageRawBytes(spec: ImageSpecV1) Error!usize {
    try validateImageSpec(spec);
    return (try rasterLayout(
        spec.width,
        spec.height,
        spec.channels,
        maximum_png_dimension,
        maximum_png_raw_bytes,
    )).raw_bytes;
}

fn expectedAnimationRawBytes(spec: AnimationSpecV1) Error!usize {
    try validateAnimationSpec(spec);
    const layout = try rasterLayout(
        spec.width,
        spec.height,
        spec.channels,
        maximum_apng_dimension,
        maximum_apng_raw_bytes / 2,
    );
    return try checkedMul(layout.raw_bytes, 2);
}

fn rasterLayout(
    width_u64: u64,
    height_u64: u64,
    channels_u64: u64,
    maximum_dimension: u64,
    maximum_raw_bytes: u64,
) Error!RasterLayout {
    if (width_u64 == 0 or
        width_u64 > maximum_dimension or
        height_u64 == 0 or
        height_u64 > maximum_dimension or
        channels_u64 == 0)
        return Error.InvalidSpec;
    const width = std.math.cast(usize, width_u64) orelse
        return Error.ArithmeticOverflow;
    const height = std.math.cast(usize, height_u64) orelse
        return Error.ArithmeticOverflow;
    const channels = std.math.cast(usize, channels_u64) orelse
        return Error.ArithmeticOverflow;
    const row_bytes = try checkedMul(width, channels);
    const raw_bytes = try checkedMul(row_bytes, height);
    if (raw_bytes == 0 or raw_bytes > maximum_raw_bytes)
        return Error.UnsupportedProfile;
    const filtered_row_bytes = try checkedAdd(row_bytes, 1);
    const filtered_bytes = try checkedMul(filtered_row_bytes, height);
    const zlib_bytes = try storedZlibBytes(filtered_bytes);
    return .{
        .width = width,
        .height = height,
        .channels = channels,
        .row_bytes = row_bytes,
        .raw_bytes = raw_bytes,
        .filtered_bytes = filtered_bytes,
        .zlib_bytes = zlib_bytes,
    };
}

fn pngColorType(spec: ImageSpecV1) Error!u8 {
    return switch (spec.channels) {
        1 => if (spec.color_model == .gray and
            spec.alpha_mode == .none) 0 else Error.UnsupportedProfile,
        2 => if (spec.color_model == .gray and
            spec.alpha_mode == .straight) 4 else Error.UnsupportedProfile,
        3 => if (spec.color_model == .rgb and
            spec.alpha_mode == .none) 2 else Error.UnsupportedProfile,
        4 => if (spec.color_model == .rgb and
            spec.alpha_mode == .straight) 6 else Error.UnsupportedProfile,
        else => Error.UnsupportedProfile,
    };
}

const ColorShape = struct {
    channels: u64,
    color_model: ColorModelV1,
    alpha_mode: AlphaModeV1,
};

fn colorShapeFromPngType(color_type: u8) Error!ColorShape {
    return switch (color_type) {
        0 => .{
            .channels = 1,
            .color_model = .gray,
            .alpha_mode = .none,
        },
        4 => .{
            .channels = 2,
            .color_model = .gray,
            .alpha_mode = .straight,
        },
        2 => .{
            .channels = 3,
            .color_model = .rgb,
            .alpha_mode = .none,
        },
        6 => .{
            .channels = 4,
            .color_model = .rgb,
            .alpha_mode = .straight,
        },
        else => Error.UnsupportedProfile,
    };
}

fn delayFraction(
    duration_ticks: u64,
    time_base_numerator: u64,
    time_base_denominator: u64,
) Error!DelayFraction {
    if (duration_ticks == 0 or
        time_base_numerator == 0 or
        time_base_denominator == 0)
        return Error.UnsupportedTiming;
    var numerator = std.math.mul(
        u64,
        duration_ticks,
        time_base_numerator,
    ) catch return Error.ArithmeticOverflow;
    var denominator = time_base_denominator;
    const divisor = std.math.gcd(numerator, denominator);
    numerator /= divisor;
    denominator /= divisor;
    if (numerator == 0 or
        numerator > std.math.maxInt(u16) or
        denominator == 0 or
        denominator > std.math.maxInt(u16))
        return Error.UnsupportedTiming;
    return .{
        .numerator = @intCast(numerator),
        .denominator = @intCast(denominator),
    };
}

fn frameControl(
    sequence: u32,
    width: u32,
    height: u32,
    delay: DelayFraction,
) [26]u8 {
    var output = [_]u8{0} ** 26;
    writeU32Be(&output, 0, sequence);
    writeU32Be(&output, 4, width);
    writeU32Be(&output, 8, height);
    writeU16Be(&output, 20, delay.numerator);
    writeU16Be(&output, 22, delay.denominator);
    return output;
}

fn inspectFrameControl(
    data: []const u8,
    expected_sequence: u32,
    expected_width: u32,
    expected_height: u32,
) Error!DelayFraction {
    if (data.len != 26 or
        readU32Be(data, 0) != expected_sequence or
        readU32Be(data, 4) != expected_width or
        readU32Be(data, 8) != expected_height or
        readU32Be(data, 12) != 0 or
        readU32Be(data, 16) != 0 or
        data[24] != 0 or
        data[25] != 0)
        return Error.InvalidFormat;
    const numerator = readU16Be(data, 20);
    const denominator = readU16Be(data, 22);
    if (numerator == 0 or
        denominator == 0 or
        std.math.gcd(numerator, denominator) != 1)
        return Error.InvalidFormat;
    return .{
        .numerator = numerator,
        .denominator = denominator,
    };
}

fn storedZlibBytes(filtered_bytes: usize) Error!usize {
    if (filtered_bytes == 0) return Error.InvalidSpec;
    const rounded = try checkedAdd(
        filtered_bytes,
        stored_block_bytes - 1,
    );
    const block_count = rounded / stored_block_bytes;
    const block_headers = try checkedMul(block_count, 5);
    return try checkedAdd(
        try checkedAdd(filtered_bytes, block_headers),
        6,
    );
}

fn writeStoredZlib(
    output: []u8,
    raw: []const u8,
    row_bytes: usize,
    height: usize,
) void {
    const filtered_row_bytes = row_bytes + 1;
    const filtered_bytes = filtered_row_bytes * height;
    std.debug.assert(output.len ==
        (storedZlibBytes(filtered_bytes) catch unreachable));
    std.debug.assert(raw.len == row_bytes * height);
    output[0] = zlib_cmf;
    output[1] = zlib_flg;
    var adler = std.hash.Adler32{};
    var cursor: usize = 2;
    var filtered_offset: usize = 0;
    while (filtered_offset < filtered_bytes) {
        const block_len = @min(
            stored_block_bytes,
            filtered_bytes - filtered_offset,
        );
        const final = filtered_offset + block_len == filtered_bytes;
        output[cursor] = if (final) 0x01 else 0x00;
        cursor += 1;
        writeU16Le(output, cursor, @intCast(block_len));
        writeU16Le(
            output,
            cursor + 2,
            ~@as(u16, @intCast(block_len)),
        );
        cursor += 4;
        const block = output[cursor .. cursor + block_len];
        fillFilteredBlock(
            block,
            raw,
            filtered_offset,
            row_bytes,
        );
        adler.update(block);
        cursor += block_len;
        filtered_offset += block_len;
    }
    writeU32Be(output, cursor, adler.adler);
    cursor += 4;
    std.debug.assert(cursor == output.len);
}

fn fillFilteredBlock(
    output: []u8,
    raw: []const u8,
    filtered_offset: usize,
    row_bytes: usize,
) void {
    const filtered_row_bytes = row_bytes + 1;
    var output_offset: usize = 0;
    while (output_offset < output.len) {
        const absolute = filtered_offset + output_offset;
        const row = absolute / filtered_row_bytes;
        const row_offset = absolute % filtered_row_bytes;
        if (row_offset == 0) {
            output[output_offset] = 0;
            output_offset += 1;
            continue;
        }
        const run = @min(
            output.len - output_offset,
            filtered_row_bytes - row_offset,
        );
        const raw_offset = row * row_bytes + row_offset - 1;
        @memcpy(
            output[output_offset .. output_offset + run],
            raw[raw_offset .. raw_offset + run],
        );
        output_offset += run;
    }
}

fn inspectStoredZlib(
    encoded: []const u8,
    row_bytes: usize,
    height: usize,
    aggregate: ?*Sha256,
) Error!RawInspection {
    const filtered_row_bytes = checkedAdd(row_bytes, 1) catch
        return Error.InvalidFormat;
    const filtered_bytes = checkedMul(
        filtered_row_bytes,
        height,
    ) catch return Error.InvalidFormat;
    const expected_zlib_bytes = storedZlibBytes(filtered_bytes) catch
        return Error.InvalidFormat;
    if (encoded.len != expected_zlib_bytes or
        encoded[0] != zlib_cmf or
        encoded[1] != zlib_flg)
        return Error.InvalidFormat;

    var adler = std.hash.Adler32{};
    var raw_hash = Sha256.init(.{});
    var cursor: usize = 2;
    var filtered_offset: usize = 0;
    while (filtered_offset < filtered_bytes) {
        if (cursor + 5 > encoded.len) return Error.InvalidFormat;
        const remaining = filtered_bytes - filtered_offset;
        const expected_block_len = @min(
            stored_block_bytes,
            remaining,
        );
        const expected_final = expected_block_len == remaining;
        const expected_header: u8 = if (expected_final) 0x01 else 0x00;
        if (encoded[cursor] != expected_header)
            return Error.InvalidFormat;
        cursor += 1;
        const block_len = readU16Le(encoded, cursor);
        const inverse_len = readU16Le(encoded, cursor + 2);
        cursor += 4;
        if (block_len != expected_block_len or
            inverse_len != ~block_len)
            return Error.InvalidFormat;
        const block_end = checkedAdd(
            cursor,
            @as(usize, block_len),
        ) catch return Error.InvalidFormat;
        if (block_end > encoded.len) return Error.InvalidFormat;
        const block = encoded[cursor..block_end];
        adler.update(block);
        try inspectFilteredBlock(
            block,
            filtered_offset,
            row_bytes,
            &raw_hash,
            aggregate,
        );
        cursor = block_end;
        filtered_offset += block.len;
    }
    if (cursor + 4 != encoded.len or
        readU32Be(encoded, cursor) != adler.adler)
        return Error.InvalidChecksum;
    var raw_sha256: Digest = undefined;
    raw_hash.final(&raw_sha256);
    return .{
        .raw_bytes = checkedMul(row_bytes, height) catch
            return Error.InvalidFormat,
        .raw_sha256 = raw_sha256,
    };
}

fn inspectFilteredBlock(
    block: []const u8,
    filtered_offset: usize,
    row_bytes: usize,
    raw_hash: *Sha256,
    aggregate: ?*Sha256,
) Error!void {
    const filtered_row_bytes = row_bytes + 1;
    var block_offset: usize = 0;
    while (block_offset < block.len) {
        const absolute = filtered_offset + block_offset;
        const row_offset = absolute % filtered_row_bytes;
        if (row_offset == 0) {
            if (block[block_offset] != 0)
                return Error.InvalidFormat;
            block_offset += 1;
            continue;
        }
        const run = @min(
            block.len - block_offset,
            filtered_row_bytes - row_offset,
        );
        const bytes = block[block_offset .. block_offset + run];
        raw_hash.update(bytes);
        if (aggregate) |hash| hash.update(bytes);
        block_offset += run;
    }
}

fn consumeSignature(encoded: []const u8) Error!usize {
    if (encoded.len < png_signature.len or
        !std.mem.eql(
            u8,
            encoded[0..png_signature.len],
            &png_signature,
        ))
        return Error.InvalidFormat;
    return png_signature.len;
}

fn takeExpectedChunk(
    encoded: []const u8,
    cursor: *usize,
    expected_kind: [4]u8,
    expected_bytes: usize,
) Error![]const u8 {
    const chunk = try takeChunk(encoded, cursor);
    if (!std.mem.eql(u8, &chunk.kind, &expected_kind) or
        chunk.data.len != expected_bytes)
        return Error.InvalidFormat;
    return chunk.data;
}

fn takeChunk(
    encoded: []const u8,
    cursor: *usize,
) Error!Chunk {
    const start = cursor.*;
    const header_end = checkedAdd(start, 8) catch
        return Error.InvalidFormat;
    if (header_end > encoded.len) return Error.InvalidFormat;
    const data_len_u32 = readU32Be(encoded, start);
    const data_len: usize = data_len_u32;
    const data_start = start + 8;
    const data_end = checkedAdd(data_start, data_len) catch
        return Error.InvalidFormat;
    const chunk_end = checkedAdd(data_end, 4) catch
        return Error.InvalidFormat;
    if (chunk_end > encoded.len) return Error.InvalidFormat;
    var kind: [4]u8 = undefined;
    @memcpy(&kind, encoded[start + 4 .. start + 8]);
    const expected_crc = std.hash.Crc32.hash(
        encoded[start + 4 .. data_end],
    );
    if (readU32Be(encoded, data_end) != expected_crc)
        return Error.InvalidChecksum;
    cursor.* = chunk_end;
    return .{
        .kind = kind,
        .data = encoded[data_start..data_end],
    };
}

fn writeChunk(
    output: []u8,
    cursor: *usize,
    kind: [4]u8,
    data: []const u8,
) void {
    const opened = openChunk(output, cursor, kind, data.len);
    @memcpy(opened.data, data);
    sealChunk(output, opened);
}

fn openChunk(
    output: []u8,
    cursor: *usize,
    kind: [4]u8,
    data_len: usize,
) OpenChunk {
    const start = cursor.*;
    writeU32Be(output, start, @intCast(data_len));
    @memcpy(output[start + 4 .. start + 8], &kind);
    const data_start = start + 8;
    const crc_offset = data_start + data_len;
    cursor.* = crc_offset + 4;
    return .{
        .type_offset = start + 4,
        .data = output[data_start..crc_offset],
        .crc_offset = crc_offset,
    };
}

fn sealChunk(output: []u8, opened: OpenChunk) void {
    const crc = std.hash.Crc32.hash(
        output[opened.type_offset..opened.crc_offset],
    );
    writeU32Be(output, opened.crc_offset, crc);
}

fn chunkBytes(data_bytes: usize) Error!usize {
    if (data_bytes > std.math.maxInt(u32))
        return Error.ArithmeticOverflow;
    return try checkedAdd(data_bytes, 12);
}

fn checkedAdd(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch
        Error.ArithmeticOverflow;
}

fn checkedMul(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch
        Error.ArithmeticOverflow;
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

fn formatContractRoot(
    encoding_abi: u64,
    identity: []const u8,
) Digest {
    var hash = Sha256.init(.{});
    hash.update(format_contract_domain);
    var abi_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &abi_bytes, encoding_abi, .little);
    hash.update(&abi_bytes);
    hash.update(identity);
    var output: Digest = undefined;
    hash.final(&output);
    return output;
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

fn writeU16Be(output: []u8, offset: usize, value: u16) void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .big);
    @memcpy(output[offset .. offset + 2], &bytes);
}

fn writeU32Be(output: []u8, offset: usize, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    @memcpy(output[offset .. offset + 4], &bytes);
}

fn readU16Le(input: []const u8, offset: usize) u16 {
    return std.mem.readInt(
        u16,
        input[offset .. offset + 2][0..2],
        .little,
    );
}

fn readU16Be(input: []const u8, offset: usize) u16 {
    return std.mem.readInt(
        u16,
        input[offset .. offset + 2][0..2],
        .big,
    );
}

fn readU32Be(input: []const u8, offset: usize) u32 {
    return std.mem.readInt(
        u32,
        input[offset .. offset + 4][0..4],
        .big,
    );
}

fn digestFromHex(hex: []const u8) !Digest {
    var output: Digest = undefined;
    _ = try std.fmt.hexToBytes(&output, hex);
    return output;
}

fn pngBindingSpec(
    spec: ImageSpecV1,
    raw: []const u8,
) PngSpecV1 {
    return .{
        .width = spec.width,
        .height = spec.height,
        .channels = spec.channels,
        .transfer_function = spec.transfer_function,
        .alpha_mode = spec.alpha_mode,
        .raw_bytes = raw.len,
        .raw_sha256 = sha256(raw),
    };
}

fn apngBindingSpec(
    spec: AnimationSpecV1,
    raw: []const u8,
) ApngSpecV1 {
    const frame_bytes = raw.len / 2;
    return .{
        .width = spec.width,
        .height = spec.height,
        .channels = spec.channels,
        .bytes_per_channel = spec.bytes_per_channel,
        .frame_count = spec.frame_count,
        .time_base_numerator = spec.time_base_numerator,
        .time_base_denominator = spec.time_base_denominator,
        .first_duration_ticks = spec.first_duration_ticks,
        .second_duration_ticks = spec.second_duration_ticks,
        .frame_bytes = frame_bytes,
        .raw_bytes = raw.len,
        .frame_sha256 = .{
            sha256(raw[0..frame_bytes]),
            sha256(raw[frame_bytes..]),
        },
        .raw_sha256 = sha256(raw),
    };
}

test "canonical linear gray PNG matches the independent vector" {
    const spec = ImageSpecV1{
        .width = 2,
        .height = 2,
        .channels = 1,
        .color_model = .gray,
        .transfer_function = .linear,
        .alpha_mode = .none,
    };
    const raw = [_]u8{ 0x20, 0x30, 0x30, 0x20 };
    var destination: [90]u8 = undefined;
    const encoded = try encodePngV1(spec, &raw, &destination);
    try std.testing.expectEqual(@as(usize, 90), encoded.len);
    var expected: [90]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &expected,
        "89504e470d0a1a0a0000000d494844520000000200000002080000000057dd52f8" ++
            "0000000467414d41000186a031e8965f00000011494441547801010600f9ff0020" ++
            "3000302001e600a1a9dbb8a00000000049454e44ae426082",
    );
    try std.testing.expectEqualSlices(u8, &expected, encoded);
    try std.testing.expectEqualDeep(
        try digestFromHex(
            "8166b7e51cc4d0ba2e88e335349ccfbaf2c016b00e2b40c41d7d3a2fff93d807",
        ),
        sha256(encoded),
    );
    const inspected = try inspectPngV1(encoded);
    try std.testing.expectEqual(spec.width, inspected.width);
    try std.testing.expectEqual(spec.height, inspected.height);
    try std.testing.expectEqual(spec.channels, inspected.channels);
    try std.testing.expectEqual(
        spec.transfer_function,
        inspected.transfer_function,
    );
    try std.testing.expectEqualDeep(
        sha256(&raw),
        inspected.raw_sha256,
    );
    try validatePngV1(encoded, pngBindingSpec(spec, &raw));
}

test "PNG supports every retained channel shape and transfer" {
    const cases = [_]ImageSpecV1{
        .{
            .width = 1,
            .height = 1,
            .channels = 1,
            .color_model = .gray,
            .transfer_function = .srgb,
            .alpha_mode = .none,
        },
        .{
            .width = 1,
            .height = 1,
            .channels = 2,
            .color_model = .gray,
            .transfer_function = .linear,
            .alpha_mode = .straight,
        },
        .{
            .width = 1,
            .height = 1,
            .channels = 3,
            .color_model = .rgb,
            .transfer_function = .srgb,
            .alpha_mode = .none,
        },
        .{
            .width = 1,
            .height = 1,
            .channels = 4,
            .color_model = .rgb,
            .transfer_function = .linear,
            .alpha_mode = .straight,
        },
    };
    var raw = [_]u8{ 1, 2, 3, 4 };
    var destination: [128]u8 = undefined;
    for (cases) |spec| {
        const bytes = raw[0..@intCast(spec.channels)];
        const encoded = try encodePngV1(
            spec,
            bytes,
            &destination,
        );
        try validatePngV1(
            encoded,
            pngBindingSpec(spec, bytes),
        );
        const inspected = try inspectPngV1(encoded);
        try std.testing.expectEqual(
            spec.color_model,
            inspected.color_model,
        );
        try std.testing.expectEqual(
            spec.alpha_mode,
            inspected.alpha_mode,
        );
    }
}

test "PNG rejects every encoded-byte mutation" {
    const spec = ImageSpecV1{
        .width = 2,
        .height = 2,
        .channels = 1,
        .color_model = .gray,
        .transfer_function = .linear,
        .alpha_mode = .none,
    };
    const raw = [_]u8{ 0x20, 0x30, 0x30, 0x20 };
    var canonical: [90]u8 = undefined;
    _ = try encodePngV1(spec, &raw, &canonical);
    for (0..canonical.len) |index| {
        var mutated = canonical;
        mutated[index] ^= 1;
        if (validatePngV1(
            &mutated,
            pngBindingSpec(spec, &raw),
        )) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "PNG spans canonical stored blocks" {
    const spec = ImageSpecV1{
        .width = 8_192,
        .height = 9,
        .channels = 1,
        .color_model = .gray,
        .transfer_function = .linear,
        .alpha_mode = .none,
    };
    const allocator = std.testing.allocator;
    const raw_bytes = try expectedImageRawBytes(spec);
    const required = try requiredPngBytesV1(spec, raw_bytes);
    const raw = try allocator.alloc(u8, raw_bytes);
    defer allocator.free(raw);
    const destination = try allocator.alloc(u8, required);
    defer allocator.free(destination);
    for (raw, 0..) |*value, index|
        value.* = @truncate(index);
    const encoded = try encodePngV1(spec, raw, destination);
    try validatePngV1(encoded, pngBindingSpec(spec, raw));
}

test "PNG preflight failures leave destination unchanged" {
    const spec = ImageSpecV1{
        .width = 2,
        .height = 2,
        .channels = 1,
        .color_model = .gray,
        .transfer_function = .linear,
        .alpha_mode = .none,
    };
    const raw = [_]u8{ 1, 2, 3, 4 };
    var short = [_]u8{0xa5} ** 89;
    try std.testing.expectError(
        Error.BufferTooSmall,
        encodePngV1(spec, &raw, &short),
    );
    try std.testing.expect(std.mem.allEqual(u8, &short, 0xa5));

    var wrong = [_]u8{0xa5} ** 90;
    try std.testing.expectError(
        Error.InvalidPayload,
        encodePngV1(spec, raw[0..3], &wrong),
    );
    try std.testing.expect(std.mem.allEqual(u8, &wrong, 0xa5));

    var alias = [_]u8{0xa5} ** 90;
    try std.testing.expectError(
        Error.BufferAlias,
        encodePngV1(spec, alias[0..4], &alias),
    );
    try std.testing.expect(std.mem.allEqual(u8, &alias, 0xa5));
}

test "canonical APNG preserves reduced unequal frame delays" {
    const spec = AnimationSpecV1{
        .width = 2,
        .height = 2,
        .time_base_numerator = 1,
        .time_base_denominator = 1_000,
        .first_duration_ticks = 2,
        .second_duration_ticks = 3,
    };
    const raw = [_]u8{ 3, 3, 3, 3, 7, 7, 7, 7 };
    var destination: [219]u8 = undefined;
    const encoded = try encodeApngV1(spec, &raw, &destination);
    try std.testing.expectEqual(@as(usize, 219), encoded.len);
    var expected: [219]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &expected,
        "89504e470d0a1a0a0000000d494844520000000200000002080000000057dd52f8" ++
            "0000000467414d41000186a031e8965f000000086163544c000000020000000184" ++
            "8aa3e60000001a6663544c00000000000000020000000200000000000000000001" ++
            "01f40000efb2e5bf00000011494441547801010600f9ff000303000303002a000d" ++
            "e203950d0000001a6663544c000000010000000200000002000000000000000000" ++
            "0303e80000b134ce940000001566644154000000027801010600f9ff0007070007" ++
            "07005a001df128c7b70000000049454e44ae426082",
    );
    try std.testing.expectEqualSlices(u8, &expected, encoded);
    try std.testing.expectEqualDeep(
        try digestFromHex(
            "068d239d13e873d7cef7ef122fa4d189c8d06ccd4fc5f94f7ebf4dda909a7dbf",
        ),
        sha256(encoded),
    );
    const inspected = try inspectApngV1(encoded);
    try std.testing.expectEqual(@as(u16, 1), inspected.delay_numerators[0]);
    try std.testing.expectEqual(@as(u16, 500), inspected.delay_denominators[0]);
    try std.testing.expectEqual(@as(u16, 3), inspected.delay_numerators[1]);
    try std.testing.expectEqual(@as(u16, 1_000), inspected.delay_denominators[1]);
    try validateApngV1(
        encoded,
        apngBindingSpec(spec, &raw),
    );
}

test "APNG rejects every encoded-byte mutation" {
    const spec = AnimationSpecV1{
        .width = 2,
        .height = 2,
        .time_base_numerator = 1,
        .time_base_denominator = 1_000,
        .first_duration_ticks = 2,
        .second_duration_ticks = 3,
    };
    const raw = [_]u8{ 3, 3, 3, 3, 7, 7, 7, 7 };
    var canonical: [219]u8 = undefined;
    _ = try encodeApngV1(spec, &raw, &canonical);
    for (0..canonical.len) |index| {
        var mutated = canonical;
        mutated[index] ^= 1;
        if (validateApngV1(
            &mutated,
            apngBindingSpec(spec, &raw),
        )) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "APNG rejects every preflight failure without writing" {
    const invalid_timing = AnimationSpecV1{
        .width = 2,
        .height = 2,
        .time_base_numerator = 1,
        .time_base_denominator = 65_537,
        .first_duration_ticks = 1,
        .second_duration_ticks = 1,
    };
    const raw = [_]u8{1} ** 8;
    var destination = [_]u8{0xa5} ** 256;
    try std.testing.expectError(
        Error.UnsupportedTiming,
        encodeApngV1(invalid_timing, &raw, &destination),
    );
    try std.testing.expect(std.mem.allEqual(
        u8,
        &destination,
        0xa5,
    ));

    const valid = AnimationSpecV1{
        .width = 2,
        .height = 2,
        .time_base_numerator = 1,
        .time_base_denominator = 1_000,
        .first_duration_ticks = 2,
        .second_duration_ticks = 3,
    };
    var short = [_]u8{0xa5} ** 218;
    try std.testing.expectError(
        Error.BufferTooSmall,
        encodeApngV1(valid, &raw, &short),
    );
    try std.testing.expect(std.mem.allEqual(u8, &short, 0xa5));

    var wrong = [_]u8{0xa5} ** 219;
    try std.testing.expectError(
        Error.InvalidPayload,
        encodeApngV1(valid, raw[0..7], &wrong),
    );
    try std.testing.expect(std.mem.allEqual(u8, &wrong, 0xa5));

    var alias = [_]u8{0xa5} ** 219;
    try std.testing.expectError(
        Error.BufferAlias,
        encodeApngV1(valid, alias[0..8], &alias),
    );
    try std.testing.expect(std.mem.allEqual(u8, &alias, 0xa5));
}

test "PNG and APNG format contract roots are stable" {
    try std.testing.expectEqualDeep(
        try digestFromHex(
            "4a976a0b4bdb38026c4844fc5d0ec64d17bbe43fd9db0a5d051915a328a8d6e2",
        ),
        pngFormatContractSha256V1(),
    );
    try std.testing.expectEqualDeep(
        try digestFromHex(
            "92ca80f8f1eed5071753f47183c6c121cb3d88752fc3232534779b2f99bb9512",
        ),
        apngFormatContractSha256V1(),
    );
}
