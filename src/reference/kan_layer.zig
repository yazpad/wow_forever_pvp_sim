const std = @import("std");
const mem = std.mem;
const kan_spline = @import("kan_spline.zig");

pub const KanLayer = struct {
    in_dim: usize,
    out_dim: usize,
    out_dim_padded: usize, // Padded to multiple of 16 for AVX-512
    num_coeffs: usize,
    coeffs: []align(kan_spline.SplineConfig.Alignment) f32,
    knots: []f32,
    knot_min: f32,
    knot_max: f32,
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator, in_dim: usize, out_dim: usize, num_coeffs: usize, k_min: f32, k_max: f32) !KanLayer {
        const p = kan_spline.SplineConfig.Order;
        const num_knots = num_coeffs + p + 1;
        
        const out_dim_padded = (out_dim + 15) & ~@as(usize, 15);
        const coeffs = try allocator.alignedAlloc(f32, kan_spline.SplineConfig.Alignment, in_dim * num_coeffs * out_dim_padded);
        errdefer allocator.free(coeffs);
        @memset(coeffs, 0.0);
        
        var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.timestamp())));
        const rand = prng.random();
        
        const std_dev = @sqrt(2.0 / @as(f32, @floatFromInt(in_dim + out_dim)));
        for (0..in_dim) |i| {
            for (0..num_coeffs) |k| {
                const base = (i * num_coeffs + k) * out_dim_padded;
                for (0..out_dim) |j| {
                    coeffs[base + j] = (rand.float(f32) * 2.0 - 1.0) * std_dev;
                }
            }
        }

        const knots = try allocator.alloc(f32, num_knots);
        errdefer allocator.free(knots);
        const h = (k_max - k_min) / @as(f32, @floatFromInt(num_coeffs - 3));
        for (knots, 0..) |*k, i| k.* = (@as(f32, @floatFromInt(i)) - 3.0) * h + k_min;

        return KanLayer{ 
            .in_dim = in_dim, 
            .out_dim = out_dim, 
            .out_dim_padded = out_dim_padded,
            .num_coeffs = num_coeffs, 
            .coeffs = coeffs, 
            .knots = knots, 
            .knot_min = k_min,
            .knot_max = k_max,
            .allocator = allocator 
        };
    }

    pub fn deinit(self: *KanLayer) void {
        self.allocator.free(self.coeffs);
        self.allocator.free(self.knots);
    }

    pub fn forward(self: KanLayer, inputs: []const f32, outputs: []f32, batch_size: usize) void {
        const h = self.knots[1] - self.knots[0];
        const inv_h = 1.0 / h;
        const vec_len = 16;
        const V = @Vector(vec_len, f32);
        
        const MAX_VECS = 16;
        const num_vecs = (self.out_dim + vec_len - 1) / vec_len;
        
        std.debug.assert(self.in_dim <= 512);

        for (0..batch_size) |b| {
            // --- PASS 1: PRECALCULATE MATH ---
            var silu_buf: [512]f32 = undefined;
            var k_base_buf: [512]usize = undefined;
            var b_vals_buf: [512][4]f32 = undefined;

            for (0..self.in_dim) |i| {
                const x_raw = inputs[b * self.in_dim + i];
                silu_buf[i] = x_raw / (1.0 + kan_spline.fast_exp(-x_raw));

                const x = std.math.clamp(x_raw, self.knot_min + 1e-6, self.knot_max - 1e-6);
                const span_float = (x - self.knots[0]) * inv_h;
                const span_idx = @as(isize, @intFromFloat(@floor(span_float)));
                const u = span_float - @as(f32, @floatFromInt(span_idx));

                b_vals_buf[i] = kan_spline.basisAll(u);
                k_base_buf[i] = @as(usize, @intCast(@max(0, span_idx - 3)));
            }

            var acc_regs: [MAX_VECS]V = undefined;
            const inv_in_dim = 1.0 / @as(f32, @floatFromInt(self.in_dim));
            for (0..num_vecs) |v| {
                var sum_silu = @as(V, @splat(0.0));
                for (0..self.in_dim) |i| {
                    sum_silu += @as(V, @splat(silu_buf[i] * inv_in_dim));
                }
                acc_regs[v] = sum_silu;
            }

            // --- PASS 2: PURE FMA ---
            for (0..self.in_dim) |i| {
                const layer_coeffs_base = i * self.num_coeffs * self.out_dim_padded;
                const b_vals = b_vals_buf[i];
                const k_base = k_base_buf[i];
                
                var v: usize = 0;
                while (v < num_vecs) : (v += 1) {
                    const j = v * vec_len;
                    var out_v = acc_regs[v];

                    for (0..4) |a| {
                        const k_u = k_base + a;
                        if (k_u < self.num_coeffs) {
                            const c_base = layer_coeffs_base + k_u * self.out_dim_padded + j;
                            const weight_v: V = self.coeffs[c_base .. c_base + vec_len][0..vec_len].*;
                            out_v += @as(V, @splat(b_vals[a])) * weight_v;
                        }
                    }
                    acc_regs[v] = out_v;
                }
            }

            // Write registers back to memory ONCE per point
            const batch_out = outputs[b * self.out_dim .. (b + 1) * self.out_dim];
            var j: usize = 0;
            var v: usize = 0;
            while (j + vec_len <= self.out_dim) : ({ j += vec_len; v += 1; }) {
                batch_out[j .. j + vec_len][0..vec_len].* = acc_regs[v];
            }
            if (j < self.out_dim) {
                for (j..self.out_dim) |rem_j| {
                    batch_out[rem_j] = acc_regs[v][rem_j - j];
                }
            }
        }
    }

    pub fn forwardWithDeriv(self: KanLayer, inputs: []const f32, outputs: []f32, jacobians: []f32, batch_size: usize) void {
        @memset(outputs[0 .. batch_size * self.out_dim], 0.0);
        @memset(jacobians[0 .. batch_size * self.out_dim * self.in_dim], 0.0);

        const h = self.knots[1] - self.knots[0];
        const inv_h = 1.0 / h;
        const vec_len = 16;
        const V = @Vector(vec_len, f32);
        
        const MAX_VECS = 16;
        const num_vecs = (self.out_dim + vec_len - 1) / vec_len;

        std.debug.assert(self.in_dim <= 512);

        for (0..batch_size) |b| {
            // --- PASS 1: PRECALCULATE MATH & GRADIENTS ---
            var silu_buf: [512]f32 = undefined;
            var silup_buf: [512]f32 = undefined;
            var k_base_buf: [512]usize = undefined;
            var b_vals_buf: [512][4]f32 = undefined;
            var bp_vals_buf: [512][4]f32 = undefined;

            for (0..self.in_dim) |i| {
                const x_raw = inputs[b * self.in_dim + i];
                const sigmoid = 1.0 / (1.0 + kan_spline.fast_exp(-x_raw));
                silu_buf[i] = x_raw * sigmoid;
                silup_buf[i] = sigmoid * (1.0 + x_raw * (1.0 - sigmoid));

                const x = std.math.clamp(x_raw, self.knot_min + 1e-6, self.knot_max - 1e-6);
                const span_float = (x - self.knots[0]) * inv_h;
                const span_idx = @as(isize, @intFromFloat(@floor(span_float)));
                const u = span_float - @as(f32, @floatFromInt(span_idx));

                b_vals_buf[i] = kan_spline.basisAll(u);
                bp_vals_buf[i] = kan_spline.derivativeAll(u, inv_h);
                k_base_buf[i] = @as(usize, @intCast(@max(0, span_idx - 3)));
            }

            // --- PASS 2: FUSED FMA ---
            var acc_regs: [MAX_VECS]V = undefined;
            const inv_in_dim = 1.0 / @as(f32, @floatFromInt(self.in_dim));
            for (0..num_vecs) |v| {
                var sum_silu = @as(V, @splat(0.0));
                for (0..self.in_dim) |i| {
                    sum_silu += @as(V, @splat(silu_buf[i] * inv_in_dim));
                }
                acc_regs[v] = sum_silu;
            }

            for (0..self.in_dim) |i| {
                const silup = silup_buf[i];
                const b_vals = b_vals_buf[i];
                const bp_vals = bp_vals_buf[i];
                const k_base = k_base_buf[i];
                const layer_coeffs_base = i * self.num_coeffs * self.out_dim_padded;

                var v: usize = 0;
                while (v < num_vecs) : (v += 1) {
                    const j = v * vec_len;
                    var out_v = acc_regs[v];

                    // Write jacobians explicitly (since they are strided by in_dim)
                    for (0..vec_len) |v_idx| {
                        if (j + v_idx < self.out_dim) {
                            jacobians[b * self.out_dim * self.in_dim + (j + v_idx) * self.in_dim + i] += silup;
                        }
                    }

                    for (0..4) |a| {
                        const k_u = k_base + a;
                        if (k_u < self.num_coeffs) {
                            const c_base = layer_coeffs_base + k_u * self.out_dim_padded + j;
                            const weight_v: V = self.coeffs[c_base .. c_base + vec_len][0..vec_len].*;
                            out_v += @as(V, @splat(b_vals[a])) * weight_v;
                            
                            for (0..vec_len) |v_idx| {
                                if (j + v_idx < self.out_dim) {
                                    jacobians[b * self.out_dim * self.in_dim + (j + v_idx) * self.in_dim + i] += bp_vals[a] * weight_v[v_idx];
                                }
                            }
                        }
                    }
                    acc_regs[v] = out_v;
                }
            }

            // Write registers back to memory ONCE per point
            const batch_out = outputs[b * self.out_dim .. (b + 1) * self.out_dim];
            var j: usize = 0;
            var v: usize = 0;
            while (j + vec_len <= self.out_dim) : ({ j += vec_len; v += 1; }) {
                batch_out[j .. j + vec_len][0..vec_len].* = acc_regs[v];
            }
            if (j < self.out_dim) {
                for (j..self.out_dim) |rem_j| {
                    batch_out[rem_j] = acc_regs[v][rem_j - j];
                }
            }
        }
    }

    pub fn backward(self: KanLayer, inputs: []const f32, out_grad: []const f32, in_grad: []f32, coeff_grads: []f32, batch_size: usize, scratch: []f32) void {
        @memset(in_grad[0 .. batch_size * self.in_dim], 0.0);

        const h = self.knots[1] - self.knots[0];
        const inv_h = 1.0 / h;
        const vec_len = 16;
        const V = @Vector(vec_len, f32);

        const BLOCK_SIZE = 256;
        var b_start: usize = 0;

        // Use scratch memory for block-local structures
        const sorted_idx = @as([*]u16, @ptrCast(scratch.ptr)); // size 256
        const k_bases = @as([*]u8, @ptrCast(scratch.ptr + 256)); // size 256
        
        while (b_start < batch_size) : (b_start += BLOCK_SIZE) {
            const b_end = @min(b_start + BLOCK_SIZE, batch_size);
            const cur_block_size = b_end - b_start;

            for (0..self.in_dim) |i| {
                const layer_coeffs_base = i * self.num_coeffs * self.out_dim_padded;

                var b_vals_block: [BLOCK_SIZE][4]f32 = undefined;
                var bp_vals_block: [BLOCK_SIZE][4]f32 = undefined;
                var silup_block: [BLOCK_SIZE]f32 = undefined;

                var counts = [_]u16{0} ** 128;

                for (0..cur_block_size) |idx| {
                    const b = b_start + idx;
                    const x_raw = inputs[b * self.in_dim + i];
                    const sigmoid = 1.0 / (1.0 + kan_spline.fast_exp(-x_raw));
                    silup_block[idx] = sigmoid * (1.0 + x_raw * (1.0 - sigmoid));

                    // sum of gradients from all output nodes for this point
                    var sum_og: f32 = 0.0;
                    for (0..self.out_dim) |j_idx| {
                        sum_og += out_grad[b * self.out_dim + j_idx];
                    }
                    const inv_in_dim = 1.0 / @as(f32, @floatFromInt(self.in_dim));
                    in_grad[b * self.in_dim + i] += (sum_og * inv_in_dim) * silup_block[idx];

                    const x = std.math.clamp(x_raw, self.knot_min + 1e-6, self.knot_max - 1e-6);
                    const span_float = (x - self.knots[0]) * inv_h;
                    const span_idx = @as(isize, @intFromFloat(@floor(span_float)));
                    const u = span_float - @as(f32, @floatFromInt(span_idx));

                    b_vals_block[idx] = kan_spline.basisAll(u);
                    bp_vals_block[idx] = kan_spline.derivativeAll(u, inv_h);
                    
                    const k_base = @as(u8, @intCast(@max(0, span_idx - 3)));
                    k_bases[idx] = k_base;
                    counts[k_base] += 1;
                }

                var offsets = [_]u16{0} ** 128;
                var current_offset: u16 = 0;
                for (0..self.num_coeffs) |k| {
                    offsets[k] = current_offset;
                    current_offset += counts[k];
                }

                var current_ptrs = offsets;
                for (0..cur_block_size) |idx| {
                    const k_base = k_bases[idx];
                    sorted_idx[current_ptrs[k_base]] = @as(u16, @intCast(idx));
                    current_ptrs[k_base] += 1;
                }

                var j: usize = 0;
                while (j + vec_len <= self.out_dim) : (j += vec_len) {
                    
                    for (0..self.num_coeffs) |k| {
                        const count = counts[k];
                        if (count == 0) continue;
                        const start_ptr = offsets[k];

                        var acc_cg_0 = @as(V, @splat(0.0));
                        var acc_cg_1 = @as(V, @splat(0.0));
                        var acc_cg_2 = @as(V, @splat(0.0));
                        var acc_cg_3 = @as(V, @splat(0.0));

                        const c_idx_0 = layer_coeffs_base + (k + 0) * self.out_dim_padded + j;
                        const w_0: V = if (k + 0 < self.num_coeffs) self.coeffs[c_idx_0 .. c_idx_0 + vec_len][0..vec_len].* else @as(V, @splat(0.0));
                        const c_idx_1 = layer_coeffs_base + (k + 1) * self.out_dim_padded + j;
                        const w_1: V = if (k + 1 < self.num_coeffs) self.coeffs[c_idx_1 .. c_idx_1 + vec_len][0..vec_len].* else @as(V, @splat(0.0));
                        const c_idx_2 = layer_coeffs_base + (k + 2) * self.out_dim_padded + j;
                        const w_2: V = if (k + 2 < self.num_coeffs) self.coeffs[c_idx_2 .. c_idx_2 + vec_len][0..vec_len].* else @as(V, @splat(0.0));
                        const c_idx_3 = layer_coeffs_base + (k + 3) * self.out_dim_padded + j;
                        const w_3: V = if (k + 3 < self.num_coeffs) self.coeffs[c_idx_3 .. c_idx_3 + vec_len][0..vec_len].* else @as(V, @splat(0.0));

                        for (0..count) |c| {
                            const idx = sorted_idx[start_ptr + c];
                            const b = b_start + idx;
                            const og_v: V = out_grad[b * self.out_dim + j ..][0..vec_len].*;
                            
                            acc_cg_0 += og_v * @as(V, @splat(b_vals_block[idx][0]));
                            acc_cg_1 += og_v * @as(V, @splat(b_vals_block[idx][1]));
                            acc_cg_2 += og_v * @as(V, @splat(b_vals_block[idx][2]));
                            acc_cg_3 += og_v * @as(V, @splat(b_vals_block[idx][3]));

                            var in_g_v = @as(V, @splat(0.0));
                            in_g_v += og_v * @as(V, @splat(bp_vals_block[idx][0])) * w_0;
                            in_g_v += og_v * @as(V, @splat(bp_vals_block[idx][1])) * w_1;
                            in_g_v += og_v * @as(V, @splat(bp_vals_block[idx][2])) * w_2;
                            in_g_v += og_v * @as(V, @splat(bp_vals_block[idx][3])) * w_3;

                            in_grad[b * self.in_dim + i] += @reduce(.Add, in_g_v);
                        }

                        if (k + 0 < self.num_coeffs) {
                            var cg: V = coeff_grads[c_idx_0 .. c_idx_0 + vec_len][0..vec_len].*;
                            cg += acc_cg_0;
                            coeff_grads[c_idx_0 .. c_idx_0 + vec_len][0..vec_len].* = cg;
                        }
                        if (k + 1 < self.num_coeffs) {
                            var cg: V = coeff_grads[c_idx_1 .. c_idx_1 + vec_len][0..vec_len].*;
                            cg += acc_cg_1;
                            coeff_grads[c_idx_1 .. c_idx_1 + vec_len][0..vec_len].* = cg;
                        }
                        if (k + 2 < self.num_coeffs) {
                            var cg: V = coeff_grads[c_idx_2 .. c_idx_2 + vec_len][0..vec_len].*;
                            cg += acc_cg_2;
                            coeff_grads[c_idx_2 .. c_idx_2 + vec_len][0..vec_len].* = cg;
                        }
                        if (k + 3 < self.num_coeffs) {
                            var cg: V = coeff_grads[c_idx_3 .. c_idx_3 + vec_len][0..vec_len].*;
                            cg += acc_cg_3;
                            coeff_grads[c_idx_3 .. c_idx_3 + vec_len][0..vec_len].* = cg;
                        }
                    }
                }

                while (j < self.out_dim) : (j += 1) {
                    for (0..self.num_coeffs) |k| {
                        const count = counts[k];
                        if (count == 0) continue;
                        const start_ptr = offsets[k];

                        var acc_cg_0: f32 = 0.0;
                        var acc_cg_1: f32 = 0.0;
                        var acc_cg_2: f32 = 0.0;
                        var acc_cg_3: f32 = 0.0;

                        const c_idx_0 = layer_coeffs_base + (k + 0) * self.out_dim_padded + j;
                        const w_0 = if (k + 0 < self.num_coeffs) self.coeffs[c_idx_0] else 0.0;
                        const c_idx_1 = layer_coeffs_base + (k + 1) * self.out_dim_padded + j;
                        const w_1 = if (k + 1 < self.num_coeffs) self.coeffs[c_idx_1] else 0.0;
                        const c_idx_2 = layer_coeffs_base + (k + 2) * self.out_dim_padded + j;
                        const w_2 = if (k + 2 < self.num_coeffs) self.coeffs[c_idx_2] else 0.0;
                        const c_idx_3 = layer_coeffs_base + (k + 3) * self.out_dim_padded + j;
                        const w_3 = if (k + 3 < self.num_coeffs) self.coeffs[c_idx_3] else 0.0;

                        for (0..count) |c| {
                            const idx = sorted_idx[start_ptr + c];
                            const b = b_start + idx;
                            const og = out_grad[b * self.out_dim + j];

                            acc_cg_0 += og * b_vals_block[idx][0];
                            acc_cg_1 += og * b_vals_block[idx][1];
                            acc_cg_2 += og * b_vals_block[idx][2];
                            acc_cg_3 += og * b_vals_block[idx][3];

                            var in_g: f32 = 0.0;
                            in_g += og * bp_vals_block[idx][0] * w_0;
                            in_g += og * bp_vals_block[idx][1] * w_1;
                            in_g += og * bp_vals_block[idx][2] * w_2;
                            in_g += og * bp_vals_block[idx][3] * w_3;

                            in_grad[b * self.in_dim + i] += in_g;
                        }

                        if (k + 0 < self.num_coeffs) coeff_grads[c_idx_0] += acc_cg_0;
                        if (k + 1 < self.num_coeffs) coeff_grads[c_idx_1] += acc_cg_1;
                        if (k + 2 < self.num_coeffs) coeff_grads[c_idx_2] += acc_cg_2;
                        if (k + 3 < self.num_coeffs) coeff_grads[c_idx_3] += acc_cg_3;
                    }
                }
            }
        }
    }
};

test "KanLayer: No Accumulation Sanity" {
    const allocator = std.testing.allocator;
    var layer = try KanLayer.init(allocator, 3, 4, 8);
    defer layer.deinit();

    const input = [_]f32{ 0.5, -0.2, 0.1 };
    const output1 = try allocator.alloc(f32, 4);
    const output2 = try allocator.alloc(f32, 4);
    defer allocator.free(output1);
    defer allocator.free(output2);

    layer.forward(&input, output1, 1);
    for (0..10) |_| { layer.forward(&input, output2, 1); }

    for (0..4) |i| { try std.testing.expectEqual(output1[i], output2[i]); }
}
