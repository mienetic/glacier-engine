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
    // Locate the metallib. The build's metal-lib step writes it to
    // zig-out/metal/shaders.metallib; tests run from the repo root.
    var backend = engine.MetalBackend.init("zig-out/metal/shaders.metallib") catch |err| {
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

    var backend = engine.MetalBackend.init("zig-out/metal/shaders.metallib") catch return error.SkipZigTest;
    defer backend.deinit();

    var out: [16]u8 = undefined;
    // Reject on the host before the Objective-C shim can read the header.
    try testing.expectError(
        engine.metal_backend.MetalError.DispatchFailed,
        backend.dequantInt4(&[_]u8{}, &out, 8),
    );
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

    var backend = engine.MetalBackend.init("zig-out/metal/shaders.metallib") catch return error.SkipZigTest;
    defer backend.deinit();
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
