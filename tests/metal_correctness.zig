//! Metal INT4 dequant — numerical equivalence with the CPU reference.
//!
//! This is the test that turns the Metal backend from "compiles cleanly"
//! into "produces correct numbers". It:
//!   1. Builds a small INT4-quantized payload in memory (qio layout).
//!   2. Decodes it on the CPU with qio.decodePage (the reference).
//!   3. Decodes the same payload on the GPU with MetalBackend.dequantInt4.
//!   4. Compares every element: Metal (FP16) vs CPU (FP32) must agree to
//!      within FP16 rounding tolerance.
//!
//! The test is only compiled when the build's `metal_enabled` flag is true
//! (i.e. macOS + -Dmetal=true). On every other target it is a no-op so the
//! full test suite still runs in CI without a Metal device.

const std = @import("std");
const engine = @import("engine");
const config = @import("config");

const testing = std.testing;

test "Metal dequant matches CPU reference within FP16 tolerance" {
    if (!config.metal_enabled) return error.SkipZigTest;

    const allocator = testing.allocator;
    const group_size: u32 = 64;
    const num_elements: usize = 256;

    // Synthetic weights with realistic scale.
    var rng = std.Random.DefaultPrng.init(99);
    var src: [256]f32 = undefined;
    for (&src) |*v| v.* = (rng.random().float(f32) * 2 - 1) * 0.4;

    // Encode as a qio payload (INT4).
    const payload = try engine.qio.encodePage(f32, allocator, &src, .int4, group_size);
    defer allocator.free(payload);

    // --- CPU reference ---------------------------------------------------
    const cpu_out = try engine.qio.decodePage(f32, allocator, payload);
    defer allocator.free(cpu_out);

    // --- Metal path ------------------------------------------------------
    // Locate the metallib generated for this exact build invocation.
    var backend = engine.MetalBackend.init(engine.metal_library_path) catch |err| {
        // No Metal device available — skip rather than fail. This lets the
        // test suite run in headless CI containers that match os.tag==macos
        // but have no GPU.
        std.debug.print("\n  [metal] no Metal device: {s} — skipping\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer backend.deinit();

    var gpu_bytes = try allocator.alloc(u8, num_elements * 2);
    defer allocator.free(gpu_bytes);
    try backend.dequantInt4(payload, gpu_bytes, @intCast(num_elements));

    // Decode the GPU's FP16 output bit-by-bit into f32 for comparison.
    var max_diff: f32 = 0;
    var i: usize = 0;
    while (i < num_elements) : (i += 1) {
        const bits = std.mem.readInt(u16, gpu_bytes[i * 2 ..][0..2], .little);
        const gpu_f32 = engine.core.f16bits.f16BitsToF32(bits);
        const cpu_f32 = cpu_out[i];
        const diff: f32 = if (gpu_f32 > cpu_f32) gpu_f32 - cpu_f32 else cpu_f32 - gpu_f32;
        if (diff > max_diff) max_diff = diff;
    }

    // Tolerance: the CPU path stays in FP32 throughout; the Metal path
    // rounds to FP16 at the end. For weights in the ±0.4 range, FP16 has
    // ~10 bits of mantissa → ~0.001 worst-case rounding. We allow 2× that
    // to absorb dequant path differences.
    try testing.expect(max_diff < 0.005);
}

test "Metal dispatch rejects malformed payload" {
    if (!config.metal_enabled) return error.SkipZigTest;

    var backend = engine.MetalBackend.init(engine.metal_library_path) catch return error.SkipZigTest;
    defer backend.deinit();

    var out: [16]u8 = undefined;
    // Reject on the host before the Objective-C shim can read the header.
    try testing.expectError(
        engine.metal_backend.MetalError.DispatchFailed,
        backend.dequantInt4(&[_]u8{}, &out, 8),
    );
}

test "Metal tiled FP16 matmul matches CPU on asymmetric edge tiles" {
    if (!config.metal_enabled) return error.SkipZigTest;

    var backend = engine.MetalBackend.init(
        engine.metal_library_path,
    ) catch return error.SkipZigTest;
    defer backend.deinit();

    // The first case is a single partial 16x16 output tile with K>N. The
    // second crosses both output-tile boundaries and has a partial K tile.
    const cases = [_]struct { m: u32, k: u32, n: u32 }{
        .{ .m = 3, .k = 19, .n = 5 },
        .{ .m = 17, .k = 7, .n = 19 },
    };
    for (cases) |case| {
        try expectMetalMatmulMatchesCpu(
            &backend,
            case.m,
            case.k,
            case.n,
        );
    }
}

test "Metal tiled FP16 matmul rejects malformed shapes without output mutation" {
    if (!config.metal_enabled) return error.SkipZigTest;

    var backend = engine.MetalBackend.init(
        engine.metal_library_path,
    ) catch return error.SkipZigTest;
    defer backend.deinit();

    const a: [8]u8 = @splat(0x11);
    const b: [8]u8 = @splat(0x22);
    var output: [8]u8 = @splat(0xA5);
    const sentinel = output;
    const matmul_failed = engine.metal_backend.MetalError.MatmulFailed;

    // Zero dimensions reject before any Objective-C/Metal call.
    try testing.expectError(
        matmul_failed,
        backend.matmulF16(&a, &b, &output, 0, 1, 1),
    );
    try testing.expectError(
        matmul_failed,
        backend.matmulF16(&a, &b, &output, 1, 0, 1),
    );
    try testing.expectError(
        matmul_failed,
        backend.matmulF16(&a, &b, &output, 1, 1, 0),
    );

    // For M=1,K=2,N=1 the exact byte lengths are A=4, B=4, C=2.
    try testing.expectError(
        matmul_failed,
        backend.matmulF16(a[0..2], b[0..4], output[0..2], 1, 2, 1),
    );
    try testing.expectError(
        matmul_failed,
        backend.matmulF16(a[0..4], b[0..2], output[0..2], 1, 2, 1),
    );
    try testing.expectError(
        matmul_failed,
        backend.matmulF16(a[0..4], b[0..4], output[0..1], 1, 2, 1),
    );
    try testing.expectError(
        matmul_failed,
        backend.matmulF16(a[0..6], b[0..4], output[0..2], 1, 2, 1),
    );

    // Overflowing byte geometry must also reject entirely on the Zig side.
    try testing.expectError(
        matmul_failed,
        backend.matmulF16(
            &a,
            &b,
            &output,
            std.math.maxInt(u32),
            std.math.maxInt(u32),
            1,
        ),
    );
    try testing.expectEqualSlices(u8, &sentinel, &output);
}

test "Metal fused INT4 matvec matches CPU packed kernel" {
    if (!config.metal_enabled) return error.SkipZigTest;

    const allocator = testing.allocator;
    const in_features: usize = 64;
    const out_features: usize = 37;
    const group_size: usize = 8;

    var rng = std.Random.DefaultPrng.init(6174);
    var weights: [in_features * out_features]f32 = undefined;
    var input: [in_features]f32 = undefined;
    for (&weights) |*value| value.* = (rng.random().float(f32) * 2 - 1) * 0.25;
    for (&input) |*value| value.* = (rng.random().float(f32) * 2 - 1);

    const quantized = try engine.core.quant.quantize(
        f32,
        allocator,
        &weights,
        .int4,
        group_size,
    );
    defer {
        allocator.free(quantized.packed_bytes);
        allocator.free(quantized.scales);
    }

    var input_tensor = try engine.core.tensor.fromF32(allocator, &.{ 1, in_features }, &input);
    defer input_tensor.deinit();
    var cpu_output = try engine.core.tensor.zerosF32(allocator, &.{ 1, out_features });
    defer cpu_output.deinit();
    try engine.int4_matmul.linearInt4OnTheFly(
        input_tensor,
        quantized.packed_bytes,
        quantized.scales,
        &.{},
        cpu_output,
        out_features,
        in_features,
        group_size,
    );

    var backend = engine.MetalBackend.init(engine.metal_library_path) catch return error.SkipZigTest;
    defer backend.deinit();
    try backend.requireInt4MatvecSupport();
    const gpu_weight = try backend.createInt4Weight(
        quantized.packed_bytes,
        quantized.scales,
        group_size,
        in_features,
        out_features,
    );
    defer backend.destroyInt4Weight(gpu_weight);

    var gpu_output: [out_features]f32 = undefined;
    try backend.matvecInt4(gpu_weight, &input, &gpu_output);
    for (cpu_output.asF32(), gpu_output) |expected, actual| {
        try testing.expectApproxEqAbs(expected, actual, 2e-5);
    }
}

fn expectMetalMatmulMatchesCpu(
    backend: *engine.MetalBackend,
    m: u32,
    k: u32,
    n: u32,
) !void {
    const m_size: usize = @intCast(m);
    const k_size: usize = @intCast(k);
    const n_size: usize = @intCast(n);
    const a_elements = try std.math.mul(usize, m_size, k_size);
    const b_elements = try std.math.mul(usize, n_size, k_size);
    const c_elements = try std.math.mul(usize, m_size, n_size);
    const a = try testing.allocator.alloc(u8, a_elements * @sizeOf(u16));
    defer testing.allocator.free(a);
    const b = try testing.allocator.alloc(u8, b_elements * @sizeOf(u16));
    defer testing.allocator.free(b);
    const output = try testing.allocator.alloc(
        u8,
        c_elements * @sizeOf(u16),
    );
    defer testing.allocator.free(output);

    for (0..a_elements) |index| {
        writeF16(a, index, deterministicHalfValue(index, 3));
    }
    for (0..b_elements) |index| {
        writeF16(b, index, deterministicHalfValue(index, 7));
    }
    @memset(output, 0xA5);

    try backend.matmulF16(a, b, output, m, k, n);

    for (0..m_size) |row| {
        for (0..n_size) |column| {
            var expected: f32 = 0;
            for (0..k_size) |inner| {
                expected += readF16(a, row * k_size + inner) *
                    readF16(b, column * k_size + inner);
            }
            const actual = readF16(output, row * n_size + column);
            try testing.expect(std.math.isFinite(actual));
            try testing.expectApproxEqAbs(expected, actual, 0.02);
        }
    }
}

fn deterministicHalfValue(index: usize, salt: usize) f32 {
    const residue: i32 = @intCast((index * 17 + salt) % 9);
    return @as(f32, @floatFromInt(residue - 4)) * 0.25;
}

fn writeF16(bytes: []u8, index: usize, value: f32) void {
    std.mem.writeInt(
        u16,
        bytes[index * @sizeOf(u16) ..][0..@sizeOf(u16)],
        engine.core.f16bits.f32ToF16Bits(value),
        .little,
    );
}

fn readF16(bytes: []const u8, index: usize) f32 {
    const bits = std.mem.readInt(
        u16,
        bytes[index * @sizeOf(u16) ..][0..@sizeOf(u16)],
        .little,
    );
    return engine.core.f16bits.f16BitsToF32(bits);
}
