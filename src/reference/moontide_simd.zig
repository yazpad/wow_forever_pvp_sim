const std = @import("std");

/// Moontide SIMD SDK
/// Provides explicit vectorized operations for SOA columns.
/// This targets 128-bit (SSE/Neon) or 256-bit (AVX) depending on target.

pub const VEC_SIZE = 8; // 8 floats = 256 bits (AVX)
pub const f32x8 = @Vector(VEC_SIZE, f32);

pub const VEC512_SIZE = 16; // 16 floats = 512 bits (AVX-512)
pub const f32x16 = @Vector(VEC512_SIZE, f32);

/// Neuromorphic Leak: potential = potential * decay
pub fn leak(potentials: []f32, decay: f32) void {
    const vdecay: f32x16 = @splat(decay);
    var i: usize = 0;
    while (i + VEC512_SIZE <= potentials.len) : (i += VEC512_SIZE) {
        const vp: f32x16 = potentials[i..][0..VEC512_SIZE].*;
        potentials[i..][0..VEC512_SIZE].* = vp * vdecay;
    }
    // Remainder
    while (i < potentials.len) : (i += 1) {
        potentials[i] *= decay;
    }
}

/// Neuromorphic Propagation: potentials[targets[i]] += weights[i]
/// Uses AVX-512 Gather/Scatter if targets are sufficiently spread out,
/// but defaults to a tight loop that Zen 5 can unroll and pipe-line.
pub fn propagate(potentials: []f32, targets: []const u32, weights: []const f32) void {
    var i: usize = 0;
    while (i < targets.len) : (i += 1) {
        const target = targets[i];
        potentials[target] += weights[i];
    }
}

test "Neuromorphic Leak SIMD" {
    var potentials = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0 };
    const decay: f32 = 0.5;
    
    leak(&potentials, decay);
    
    try std.testing.expectEqual(@as(f32, 0.5), potentials[0]);
    try std.testing.expectEqual(@as(f32, 8.0), potentials[15]);
    try std.testing.expectEqual(@as(f32, 8.5), potentials[16]);
}

pub fn add(dest: []f32, a: []const f32, b: []const f32) void {
    var i: usize = 0;
    while (i + VEC_SIZE <= dest.len) : (i += VEC_SIZE) {
        const va: f32x8 = a[i..][0..VEC_SIZE].*;
        const vb: f32x8 = b[i..][0..VEC_SIZE].*;
        dest[i..][0..VEC_SIZE].* = va + vb;
    }
    // Handle remainder
    while (i < dest.len) : (i += 1) {
        dest[i] = a[i] + b[i];
    }
}

pub fn sub(dest: []f32, a: []const f32, b: []const f32) void {
    var i: usize = 0;
    while (i + VEC_SIZE <= dest.len) : (i += VEC_SIZE) {
        const va: f32x8 = a[i..][0..VEC_SIZE].*;
        const vb: f32x8 = b[i..][0..VEC_SIZE].*;
        dest[i..][0..VEC_SIZE].* = va - vb;
    }
    while (i < dest.len) : (i += 1) {
        dest[i] = a[i] - b[i];
    }
}

pub fn mul(dest: []f32, a: []const f32, b: []const f32) void {
    var i: usize = 0;
    while (i + VEC_SIZE <= dest.len) : (i += VEC_SIZE) {
        const va: f32x8 = a[i..][0..VEC_SIZE].*;
        const vb: f32x8 = b[i..][0..VEC_SIZE].*;
        dest[i..][0..VEC_SIZE].* = va * vb;
    }
    while (i < dest.len) : (i += 1) {
        dest[i] = a[i] * b[i];
    }
}

pub fn mulf(dest: []f32, a: []const f32, scalar: f32) void {
    const vs: f32x8 = @splat(scalar);
    var i: usize = 0;
    while (i + VEC_SIZE <= dest.len) : (i += VEC_SIZE) {
        const va: f32x8 = a[i..][0..VEC_SIZE].*;
        dest[i..][0..VEC_SIZE].* = va * vs;
    }
    while (i < dest.len) : (i += 1) {
        dest[i] = a[i] * scalar;
    }
}

pub fn madd(dest: []f32, a: []const f32, b: []const f32, c: []const f32) void {
    // dest = a * b + c
    var i: usize = 0;
    while (i + VEC_SIZE <= dest.len) : (i += VEC_SIZE) {
        const va: f32x8 = a[i..][0..VEC_SIZE].*;
        const vb: f32x8 = b[i..][0..VEC_SIZE].*;
        const vc: f32x8 = c[i..][0..VEC_SIZE].*;
        dest[i..][0..VEC_SIZE].* = va * vb + vc;
    }
    while (i < dest.len) : (i += 1) {
        dest[i] = a[i] * b[i] + c[i];
    }
}

pub const f32x4 = @Vector(4, f32);

/// Multiply two 4x4 matrices (SIMD accelerated)
pub fn matMul4x4(dest: *[16]f32, a: *const [16]f32, b: *const [16]f32) void {
    const b0: f32x4 = b[0..4].*;
    const b1: f32x4 = b[4..8].*;
    const b2: f32x4 = b[8..12].*;
    const b3: f32x4 = b[12..16].*;

    for (0..4) |i| {
        const row_offset = i * 4;
        const v_a0: f32x4 = @splat(a[row_offset + 0]);
        const v_a1: f32x4 = @splat(a[row_offset + 1]);
        const v_a2: f32x4 = @splat(a[row_offset + 2]);
        const v_a3: f32x4 = @splat(a[row_offset + 3]);

        const res = v_a0 * b0 + v_a1 * b1 + v_a2 * b2 + v_a3 * b3;
        dest[row_offset .. row_offset + 4][0..4].* = res;
    }
}
