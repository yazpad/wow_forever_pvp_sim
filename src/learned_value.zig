//! Experimental value-only networks. Schema 1; no dependency on legacy trainers.
const std = @import("std");
const Spec = @import("spec.zig").Spec;
pub const Inputs = 58;
pub const Hidden = 16;
pub const Network = struct {
    w: [Hidden][Inputs]f32,
    bias: [Hidden]f32,
    out: [Hidden]f32,
    out_bias: f32,
    pub fn predict(self: *const Network, x: [Inputs]f32) f32 {
        var y = self.out_bias;
        for (self.w, self.bias, self.out) |row, bias, weight| {
            var h = bias;
            for (row, x) |v, input| h += v * input;
            y += @max(0, h) * weight;
        }
        return std.math.tanh(y);
    }
};
pub const Bundle = struct {
    schema: u32 = 1,
    fingerprint: []const u8,
    mode: enum { shared, class },
    networks: [2]Network,
    pub fn predict(self: *const Bundle, spec: Spec, x: [Inputs]f32) f32 {
        return self.networks[if (self.mode == .shared or spec == .warlock) 0 else 1].predict(x);
    }
};
/// Canonical acting-player perspective. Pair reversal swaps the two halves.
/// Pilot uses base kits only; arbitrary talent/build conditioning is deferred.
pub fn features(comptime a: Spec, comptime b: Spec, comptime side: bool, d: anytype, lane: usize, limit: u32) [Inputs]f32 {
    const own = if (side) "_a" else "_b";
    const enemy = if (side) "_b" else "_a";
    const s = d.arena.combat();
    var x: [Inputs]f32 = @splat(0);
    x[0] = if ((if (side) a else b) == .warlock) 1 else 0;
    x[1] = if ((if (side) b else a) == .warlock) 1 else 0;
    x[2] = s.distance[lane] / 35;
    x[3] = @as(f32, @floatFromInt(d.ticks[lane])) / @as(f32, @floatFromInt(limit));
    const names = .{ "hp", "mana", "gcd", "cast_timer", "agony_timer", "corruption_timer", "siphon_timer", "immolate_timer", "fear_timer", "horror_timer", "seduction_timer", "action6_cd", "action6_dur", "death_coil_cd", "shadowburn_cd", "pet_hp", "move_intent", "cast_total", "fear_dr_tier", "soul_shards" };
    const scales = [_]f32{ 2000, 3000, 1.5, 5, 18, 14, 30, 15, 10, 3, 15, 120, 10, 120, 15, 2000, 1, 5, 4, 5 };
    inline for (.{ own, enemy }, 0..) |suffix, j| {
        inline for (names, 0..) |name, i| x[4 + j * 20 + i] = @field(s, name ++ suffix)[lane] / scales[i];
    }
    const fa = if (a == .frost_mage or a == .priest) d.arena.frostTelemetry(true, lane) else [_]f32{0} ** 5;
    const fb = if (b == .frost_mage or b == .priest) d.arena.frostTelemetry(false, lane) else [_]f32{0} ** 5;
    const frost_scales = [_]f32{ 15, 25, 500, 8, 10 };
    for (if (side) fa else fb, if (side) fb else fa, frost_scales, 0..) |v, u, scale, i| {
        x[44 + i] = v / scale;
        x[49 + i] = u / scale;
    }
    const pa = @import("projectiles.zig").pendingEffects(s, side, lane);
    const pb = @import("projectiles.zig").pendingEffects(s, !side, lane);
    x[54] = pa.damage / 2000;
    x[55] = pb.damage / 2000;
    x[56] = pa.healing / 2000;
    x[57] = pb.healing / 2000;
    for (&x) |*v| v.* = std.math.clamp(v.*, -2, 2);
    return x;
}

test "network zero and constant inference" {
    var n: Network = .{ .w = @splat(@splat(0)), .bias = @splat(0), .out = @splat(0), .out_bias = 0 };
    try std.testing.expectEqual(@as(f32, 0), n.predict(@splat(1)));
    n.out_bias = 0.5;
    try std.testing.expectApproxEqAbs(std.math.tanh(@as(f32, 0.5)), n.predict(@splat(0)), 0.00001);
}
