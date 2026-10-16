//! MVP pets: one autonomous slot per warlock, fixed opposing-player target.
//! Deliberately no mana, target selector, orders, or extra MCTS decisions.
const std = @import("std");
const simd = @import("simd.zig");
const V = simd.f32x16;
const U = simd.u32x16;
const B = simd.bool16;
pub const Kind = enum(u32) {
    none,
    imp,
    succubus,
    felhunter,
    voidwalker,
    pub fn parse(name: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, name);
    }
    pub fn maxHp(kind: Kind) f32 {
        return switch (kind) {
            .none => 0,
            .imp => 500,
            .succubus => 700,
            .felhunter => 900,
            .voidwalker => 1200,
        };
    }
};
pub const AttackInterval: f32 = 2;
pub const RunSpeed: f32 = 7;
pub const FireboltRange: f32 = 30;
pub const MeleeRange: f32 = 3;
fn v(x: f32) V {
    return @splat(x);
}
fn col(state: anytype, comptime name: []const u8, comptime side: bool, i: usize) *align(4) V {
    return @ptrCast(@field(state, name ++ (if (side) "_a" else "_b"))[i..][0..16]);
}
pub fn set(state: anytype, comptime side: bool, lane: usize, kind: Kind) void {
    const suffix = if (side) "_a" else "_b";
    @field(state, "pet_kind" ++ suffix)[lane] = @intFromEnum(kind);
    @field(state, "pet_hp" ++ suffix)[lane] = kind.maxHp();
    @field(state, "pet_timer" ++ suffix)[lane] = if (kind == .imp) AttackInterval else 0;
    @field(state, "pet_x" ++ suffix)[lane] = if (kind == .none) 0 else @field(state, "pos_x" ++ suffix)[lane];
    @field(state, "pet_y" ++ suffix)[lane] = if (kind == .none) 0 else @field(state, "pos_y" ++ suffix)[lane] + 1.5;
    @field(state, "impact_pet" ++ suffix)[lane] = 0;
}
pub fn tick(state: anytype, comptime side: bool, i: usize, dt: f32, imp_firebolt_damage: V) V {
    const kind: U = @field(state, if (side) "pet_kind_a" else "pet_kind_b")[i..][0..16].*;
    var live = simd.vAnd16(kind != @as(U, @splat(0)), col(state, "pet_hp", side, i).* > v(0));
    live = simd.vAnd16(live, state.is_active[i..][0..16].* != @as(U, @splat(0)));
    live = simd.vAnd16(live, simd.vAnd16(col(state, "hp", side, i).* > v(0), col(state, "hp", !side, i).* > v(0)));
    if (!@reduce(.Or, live)) return v(0);
    const imp: B = kind == @as(U, @splat(@intFromEnum(Kind.imp)));
    const succubus: B = kind == @as(U, @splat(@intFromEnum(Kind.succubus)));
    const seduction_casting = simd.vAnd16(succubus, col(state, "seduction_cast", side, i).* > v(0));
    const range = @select(f32, imp, v(FireboltRange), v(MeleeRange));
    const x = col(state, "pet_x", side, i);
    const y = col(state, "pet_y", side, i);
    const dx = col(state, "pos_x", !side, i).* - x.*;
    const dy = col(state, "pos_y", !side, i).* - y.*;
    const dist = @sqrt(dx * dx + dy * dy);
    const travel = @select(f32, seduction_casting, v(0), @min(v(RunSpeed * dt), @max(v(0), dist - range)));
    const step = @select(f32, live, travel / @max(v(0.00001), dist), v(0));
    x.* += dx * step;
    y.* += dy * step;
    const in_range = dist - travel <= range + v(0.0001);
    const timer = col(state, "pet_timer", side, i);
    var next = @max(v(0), timer.* - v(dt));
    // Imp Firebolt is a simple 2s stationary cast with immediate damage at
    // completion. Leaving range cancels it; no shared player projectile slots.
    next = @select(f32, simd.vAnd16(imp, simd.vNot16(in_range)), v(AttackInterval), next);
    const hit = simd.vAnd16(live, simd.vAnd16(in_range, simd.vAnd16(next <= v(0), simd.vNot16(seduction_casting))));
    next = @select(f32, hit, v(AttackInterval), next);
    timer.* = @select(f32, live, next, timer.*);
    const damage = @select(f32, imp, v(60), @select(f32, kind == @as(U, @splat(@intFromEnum(Kind.succubus))), v(50), @select(f32, kind == @as(U, @splat(@intFromEnum(Kind.felhunter))), v(40), v(30))));
    const resolution = @import("spell_resolution.zig");
    const fire = resolution.resolve(state, side, i, imp_firebolt_damage, simd.vAnd16(hit, imp), .{ .school = .fire, .pet = true });
    const melee = resolution.petMelee(state, side, i, damage, simd.vAnd16(hit, simd.vNot16(imp)));
    return fire.damage + melee;
}
// Same proportional shield/overkill accounting used by player missiles.
pub fn recordDamage(state: anytype, comptime side: bool, i: usize, mitigated: V, incoming: V, applied: V) void {
    col(state, "impact_pet", side, i).* = mitigated * @select(f32, incoming > v(0), applied / @max(v(0.00001), incoming), v(0));
}
// Appended replay columns, five per side: kind, HP, x, y, attack timer.
pub fn telemetry(state: anytype, lane: usize) [10]f32 {
    var result: [10]f32 = undefined;
    inline for (.{ true, false }, 0..) |side, j| {
        const suffix = if (side) "_a" else "_b";
        result[j * 5] = @floatFromInt(@field(state, "pet_kind" ++ suffix)[lane]);
        inline for (.{ "pet_hp", "pet_x", "pet_y", "pet_timer" }, 1..) |name, k| result[j * 5 + k] = @field(state, name ++ suffix)[lane];
    }
    return result;
}
