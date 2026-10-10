const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

/// B-Spline Configuration
pub const SplineConfig = struct {
    pub const Order = 3; // Cubic B-Splines (Degree 3)
    pub const Alignment = 64;
};

/// Analytical Piecewise Cubic B-Spline Basis Function.
/// This replaces the recursive Cox-de Boor for massive performance gains.
/// Assumes uniform knot spacing.
/// Calculates all 4 non-zero cubic B-spline basis functions branchlessly.
pub fn basisAll(u: f32) [4]f32 {
    const s2 = u * u;
    const s3 = s2 * u;
    const inv6 = 1.0 / 6.0;

    return .{
        inv6 * (1.0 - 3.0*u + 3.0*s2 - s3),         // N_{i-3}
        inv6 * (4.0 - 6.0*s2 + 3.0*s3),             // N_{i-2}
        inv6 * (1.0 + 3.0*u + 3.0*s2 - 3.0*s3),     // N_{i-1}
        inv6 * s3                                   // N_{i}
    };
}

/// Calculates all 4 non-zero cubic B-spline derivatives branchlessly.
pub fn derivativeAll(u: f32, inv_h: f32) [4]f32 {
    const s2 = u * u;
    const scale = 0.5 * inv_h;

    return .{
        scale * (-1.0 + 2.0*u - s2),    // N'_{i-3}
        scale * (-4.0*u + 3.0*s2),      // N'_{i-2}
        scale * (1.0 + 2.0*u - 3.0*s2), // N'_{i-1}
        scale * s2                      // N'_{i}
    };
}

/// Vectorized basis evaluation for 16 points at once.
/// u_vec: relative offsets [0, 1) for 16 points.
pub fn basisAllSimd(u_vec: @Vector(16, f32)) [4]@Vector(16, f32) {
    const V = @Vector(16, f32);
    const s2 = u_vec * u_vec;
    const s3 = s2 * u_vec;
    const inv6 = @as(V, @splat(1.0 / 6.0));
    const ones = @as(V, @splat(1.0));
    const threes = @as(V, @splat(3.0));
    const fours = @as(V, @splat(4.0));
    const sixes = @as(V, @splat(6.0));

    return .{
        inv6 * (ones - threes*u_vec + threes*s2 - s3),
        inv6 * (fours - sixes*s2 + threes*s3),
        inv6 * (ones + threes*u_vec + threes*s2 - threes*s3),
        inv6 * s3
    };
}

/// Vectorized derivative evaluation for 16 points at once.
pub fn derivativeAllSimd(u_vec: @Vector(16, f32), inv_h: f32) [4]@Vector(16, f32) {
    const V = @Vector(16, f32);
    const s2 = u_vec * u_vec;
    const scale = @as(V, @splat(0.5 * inv_h));
    const ones = @as(V, @splat(1.0));
    const twos = @as(V, @splat(2.0));
    const threes = @as(V, @splat(3.0));
    const fours = @as(V, @splat(4.0));

    return .{
        scale * (-ones + twos*u_vec - s2),
        scale * (-fours*u_vec + threes*s2),
        scale * (ones + twos*u_vec - threes*s2),
        scale * s2
    };
}

/// Fast approximate exponential for activation functions.
pub fn fast_exp(x_raw: f32) f32 {
    // Clamp to prevent integer overflow in the trick
    const x = std.math.clamp(x_raw, -80.0, 80.0);
    // Schraudolph's trick
    const i = @as(i32, @intFromFloat(12102203.0 * x + 1064866805.0));
    return @as(f32, @bitCast(i));
}

/// Vectorized fast exponential.
pub fn fast_exp_vec(x_v_raw: @Vector(16, f32)) @Vector(16, f32) {
    const V = @Vector(16, f32);
    const VI = @Vector(16, i32);
    const mins = @as(V, @splat(-80.0));
    const maxs = @as(V, @splat(80.0));
    
    // Manual clamp for SIMD
    const x_v = @select(f32, x_v_raw < mins, mins, @select(f32, x_v_raw > maxs, maxs, x_v_raw));

    const m = @as(V, @splat(12102203.0));
    const b = @as(V, @splat(1064866805.0));
    
    const i_v = @as(VI, @intFromFloat(x_v * m + b));
    return @as(V, @bitCast(i_v));
}
/// Compatibility function for single basis evaluation.
pub fn basis(i: usize, p: usize, x: f32, knots: []const f32) f32 {
    _ = p;
    const h = knots[1] - knots[0];
    const t = (x - knots[i]) / h;

    if (t < 0.0 or t >= 4.0) return 0.0;

    if (t < 1.0) {
        return 0.16666667 * t * t * t;
    } else if (t < 2.0) {
        const t1 = t - 1.0;
        return 0.16666667 * (1.0 + 3.0 * t1 + 3.0 * t1 * t1 - 3.0 * t1 * t1 * t1);
    } else if (t < 3.0) {
        const t2 = t - 2.0;
        return 0.16666667 * (4.0 - 6.0 * t2 * t2 + 3.0 * t2 * t2 * t2);
    } else {
        const t3 = t - 3.0;
        const d = 1.0 - t3;
        return 0.16666667 * d * d * d;
    }
}

/// Structure of Arrays (SoA) Evaluation.
pub fn evaluateEdges(
    x_raw: f32,
    knots: []const f32,
    coeffs: []const f32,
    num_coeffs: usize,
    num_edges: usize,
    results: []f32,
) void {
    @memset(results[0..num_edges], 0.0);
    
    const h = knots[1] - knots[0];
    // Clamp x to ensure we always have 4 basis functions (k-3 to k)
    // Safe range is [knots[3], knots[num_coeffs]]
    const safe_min = knots[3];
    const safe_max = knots[num_coeffs];
    const x = std.math.clamp(x_raw, safe_min, safe_max - 1e-5);

    const i_float = (x - knots[0]) / h;
    const i = @as(isize, @intFromFloat(@floor(i_float)));
    
    var k: isize = i - 3;
    while (k <= i) : (k += 1) {
        if (k < 0 or k >= @as(isize, @intCast(num_coeffs))) continue;
        if (@as(usize, @intCast(k)) >= knots.len) continue;

        const b_val = basis(@as(usize, @intCast(k)), 3, x, knots);
        if (b_val == 0.0) continue;

        for (0..num_edges) |e| {
            results[e] += b_val * coeffs[@as(usize, @intCast(k)) * num_edges + e];
        }
    }
}

/// Vectorized SoA Evaluation (AVX-512)
pub fn evaluateEdgesSimd(
    x_raw: f32,
    knots: []const f32,
    coeffs: []const f32,
    num_coeffs: usize,
    results: *[16]f32,
) void {
    const Vector = @Vector(16, f32);
    var sums = @as(Vector, @splat(0.0));

    const h = knots[1] - knots[0];
    const safe_min = knots[3];
    const safe_max = knots[num_coeffs];
    const x = std.math.clamp(x_raw, safe_min, safe_max - 1e-5);

    const i_float = (x - knots[0]) / h;
    const i = @as(isize, @intFromFloat(@floor(i_float)));

    var k: isize = i - 3;
    while (k <= i) : (k += 1) {
        if (k < 0 or k >= @as(isize, @intCast(num_coeffs))) continue;
        if (@as(usize, @intCast(k)) >= knots.len) continue;

        const b_val = basis(@as(usize, @intCast(k)), 3, x, knots);
        if (b_val == 0.0) continue;

        const b_vec = @as(Vector, @splat(b_val));
        const c_vec: Vector = coeffs[@as(usize, @intCast(k)) * 16 ..][0..16].*;
        sums += b_vec * c_vec;
    }
    results.* = sums;
}

test "B-Spline Basis: Analytical Parity" {
    const knots = [_]f32{ 0.0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.2, 1.4 };
    // N_{0,3}(x) is non-zero from 0 to 0.8
    try std.testing.expect(basis(0, 3, 0.1, &knots) > 0);
    try std.testing.expect(basis(0, 3, 0.9, &knots) == 0);
}
