//! FP16 (IEEE 754 half) bit-level helpers.
//!
//! Metal writes its dequant output as FP16 (`half`). The CPU reference
//! path produces FP32. To compare the two we need to interpret a stream
//! of u16 bit patterns as FP32 values. We do this manually rather than
//! relying on hardware f16 conversion so the comparison is deterministic
//! across platforms (and works even where `@as(f16, ...)` would need
//! software support).
//!
//! Reference: IEEE 754-2008 binary16 — 1 sign, 5 exponent, 10 mantissa.

const std = @import("std");

/// Reinterpret a u16 bit pattern as f32 (extending the value losslessly).
pub fn f16BitsToF32(bits: u16) f32 {
    const sign: u32 = (@as(u32, bits) >> 15) & 0x1;
    const exp: u32 = (@as(u32, bits) >> 10) & 0x1F;
    const mant: u32 = @as(u32, bits) & 0x3FF;

    if (exp == 0) {
        if (mant == 0) {
            // ±0
            return if (sign == 1) -0.0 else 0.0;
        }
        // Subnormal: normalize.
        const f32_mant: u32 = mant;
        var e: i32 = -14;
        var m: u32 = f32_mant;
        while ((m & 0x400) == 0) {
            m <<= 1;
            e -= 1;
        }
        m &= 0x3FF;
        const new_exp: u32 = @intCast(e + 127);
        const out: u32 = (sign << 31) | (new_exp << 23) | (m << 13);
        return @bitCast(out);
    }
    if (exp == 0x1F) {
        // Inf or NaN.
        const out: u32 = (sign << 31) | (0xFF << 23) | (mant << 13);
        return @bitCast(out);
    }
    // Normalized.
    const new_exp_signed: i32 = @as(i32, @intCast(exp)) - 15 + 127;
    const new_exp: u32 = @intCast(new_exp_signed);
    const out: u32 = (sign << 31) | (new_exp << 23) | (mant << 13);
    return @bitCast(out);
}

/// Round-trip an f32 to f16 bits and back. Lossy at the f16 precision.
pub fn f32ToF16Bits(v: f32) u16 {
    const u: u32 = @bitCast(v);
    const sign: u32 = (u >> 31) & 0x1;
    const exp: u32 = (u >> 23) & 0xFF;
    const mant: u32 = u & 0x7FFFFF;

    if (exp == 0xFF) {
        // Inf or NaN — preserve sign, set exponent bits, keep top mantissa bit.
        return @intCast((sign << 15) | (0x1F << 10) | if (mant != 0) @as(u32, 1) else 0);
    }

    const new_exp_signed: i32 = @intCast(exp);
    const unbiased: i32 = new_exp_signed - 127;
    if (unbiased > 15) {
        // Overflow → Inf.
        return @intCast((sign << 15) | (0x1F << 10));
    }
    if (unbiased < -14) {
        // Underflow → 0 or subnormal. For our use case (weight values, mostly
        // small magnitudes) we just zero it; round-to-nearest would add bias
        // but this is a comparison helper, not a kernel.
        return @intCast(sign << 15);
    }
    const biased: u32 = @intCast(unbiased + 15);
    const mant10: u32 = mant >> 13;
    return @intCast((sign << 15) | (biased << 10) | mant10);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "f16 → f32: zero, identity, sign" {
    try testing.expectEqual(@as(f32, 0.0), f16BitsToF32(0x0000));
    try testing.expectEqual(@as(f32, -0.0), f16BitsToF32(0x8000));
    try testing.expectEqual(@as(f32, 1.0), f16BitsToF32(0x3C00));
    try testing.expectEqual(@as(f32, -1.0), f16BitsToF32(0xBC00));
    try testing.expectEqual(@as(f32, 2.0), f16BitsToF32(0x4000));
}

test "f16 → f32: small subnormal" {
    // Smallest subnormal: 2^-24.
    const v = f16BitsToF32(0x0001);
    try testing.expectApproxEqAbs(@as(f32, 5.96e-8), v, 1e-9);
}

test "f16 → f32: inf and nan" {
    const inf = f16BitsToF32(0x7C00);
    try testing.expect(std.math.isPositiveInf(inf));
    const ninf = f16BitsToF32(0xFC00);
    try testing.expect(std.math.isNegativeInf(ninf));
    const nan = f16BitsToF32(0x7C01);
    try testing.expect(std.math.isNan(nan));
}

test "round-trip simple values through f16" {
    // 1.0, 2.0, 0.5 — all exactly representable in f16.
    try testing.expectEqual(@as(f32, 1.0), f16BitsToF32(f32ToF16Bits(1.0)));
    try testing.expectEqual(@as(f32, 2.0), f16BitsToF32(f32ToF16Bits(2.0)));
    try testing.expectEqual(@as(f32, 0.5), f16BitsToF32(f32ToF16Bits(0.5)));
}
