const std = @import("std");

/// SIMD Configuration and Widths
pub const SimdConfig = struct {
    pub const Alignment = 64; // 64-byte alignment matches cache line & AVX-512 ZMM registers
    pub const VecLen16 = 16;  // 16 floats = 512 bits (AVX-512)
    pub const VecLen8 = 8;    // 8 floats = 256 bits (AVX2)
    pub const VecLen4 = 4;    // 4 floats = 128 bits (SSE / Neon)
};

pub const f32x16 = @Vector(SimdConfig.VecLen16, f32);
pub const u32x16 = @Vector(SimdConfig.VecLen16, u32);
pub const i32x16 = @Vector(SimdConfig.VecLen16, i32);
pub const bool16 = @Vector(SimdConfig.VecLen16, bool);

pub const f32x8 = @Vector(SimdConfig.VecLen8, f32);
pub const u32x8 = @Vector(SimdConfig.VecLen8, u32);
pub const bool8 = @Vector(SimdConfig.VecLen8, bool);

/// Branchless clamp for 16-wide vector: clamp(x, min_val, max_val)
pub inline fn clamp16(v: f32x16, min_v: f32x16, max_v: f32x16) f32x16 {
    return @min(@max(v, min_v), max_v);
}

/// Branchless clamp for 8-wide vector
pub inline fn clamp8(v: f32x8, min_v: f32x8, max_v: f32x8) f32x8 {
    return @min(@max(v, min_v), max_v);
}

/// Branchless select: cond ? true_val : false_val
pub inline fn select16(cond: bool16, true_val: f32x16, false_val: f32x16) f32x16 {
    return @select(f32, cond, true_val, false_val);
}

/// Vector boolean AND: a & b
pub inline fn vAnd16(a: bool16, b: bool16) bool16 {
    return @select(bool, a, b, @as(bool16, @splat(false)));
}

/// Vector boolean OR: a | b
pub inline fn vOr16(a: bool16, b: bool16) bool16 {
    return @select(bool, a, @as(bool16, @splat(true)), b);
}

/// Vector boolean NOT: !a
pub inline fn vNot16(a: bool16) bool16 {
    return @select(bool, a, @as(bool16, @splat(false)), @as(bool16, @splat(true)));
}

/// Fused Multiply-Add (a * b + c)
pub inline fn fma16(a: f32x16, b: f32x16, c: f32x16) f32x16 {
    return a * b + c;
}

/// Fast polynomial approximation of exp(-x) for positive x
/// Useful for exponential damage decay, status dropoff, or neural activations
pub inline fn fastExpNeg(x: f32x16) f32x16 {
    const ones: f32x16 = @splat(1.0);
    // 1 / (1 + x + 0.48*x^2 + 0.235*x^3) approx
    const c2: f32x16 = @splat(0.48);
    const c3: f32x16 = @splat(0.235);
    const x2 = x * x;
    const x3 = x2 * x;
    const denom = ones + x + c2 * x2 + c3 * x3;
    return ones / denom;
}

/// Horizontal sum reduction for 16 floats
pub inline fn reduceAdd16(v: f32x16) f32 {
    return @reduce(.Add, v);
}

/// Horizontal sum reduction for 8 floats
pub inline fn reduceAdd8(v: f32x8) f32 {
    return @reduce(.Add, v);
}

test "simd basics" {
    const a: f32x16 = @splat(2.0);
    const b: f32x16 = @splat(3.0);
    const c: f32x16 = @splat(1.0);
    const res = fma16(a, b, c);
    try std.testing.expectEqual(@as(f32, 7.0), res[0]);
    try std.testing.expectEqual(@as(f32, 7.0), res[15]);

    const clamped = clamp16(res, @splat(0.0), @splat(5.0));
    try std.testing.expectEqual(@as(f32, 5.0), clamped[0]);
}
