//! Conflagrate state shared by mirror and mixed-class combat kernels.
const simd = @import("simd.zig");
const talents = @import("warlock_talents.zig");
const C = @import("combat_spec.zig").WarlockConstants;
const V = simd.f32x16;
const U = simd.u32x16;
const B = simd.bool16;
fn v(x: f32) V {
    return @splat(x);
}
fn col(state: anytype, comptime name: []const u8, comptime side: bool, i: usize) *align(4) V {
    return @ptrCast(@field(state, name ++ (if (side) "_a" else "_b"))[i..][0..16]);
}
fn flags(state: anytype, comptime side: bool, i: usize) U {
    return @field(state, "talent_flags" ++ (if (side) "_a" else "_b"))[i..][0..16].*;
}
pub fn legal(state: anytype, comptime side: bool, i: usize, free: B) B {
    const unlocked = (flags(state, side, i) & @as(U, @splat(1 << 8))) != @as(U, @splat(0));
    return simd.vAnd16(free, simd.vAnd16(unlocked, simd.vAnd16(col(state, "immolate_timer", !side, i).* > v(0), simd.vAnd16(col(state, "conflagrate_cd", side, i).* <= v(0), simd.vAnd16(col(state, "mana", side, i).* >= v(C.ConflagrateMana), @as(V, state.distance[i..][0..16].*) <= v(C.ConflagrateRange))))));
}
// Integer state is part of snapshots. Only acting lanes advance, so replay and
// batching produce the same proc outcomes. Two independent draws per cast.
fn roll(state: anytype, comptime side: bool, i: usize, mask: B) V {
    const values = @field(state, "conflagrate_rng" ++ (if (side) "_a" else "_b"));
    const old: U = values[i..][0..16].*;
    var next = old ^ (old << @as(@Vector(16, u5), @splat(13)));
    next ^= next >> @as(@Vector(16, u5), @splat(17));
    next ^= next << @as(@Vector(16, u5), @splat(5));
    values[i..][0..16].* = @select(u32, mask, next, old);
    return @as(V, @floatFromInt(next >> @as(@Vector(16, u5), @splat(8)))) * v(1.0 / 16777216.0);
}
pub fn apply(state: anytype, comptime side: bool, i: usize, mask: B, effects: talents.Effects, immolate: *V) void {
    if (!@reduce(.Or, mask)) return;
    const resolved = @import("spell_resolution.zig").resolve(state, side, i, v(C.ConflagrateDamage), mask, .{
        .school = .fire,
        .hit_bonus = effects.spell_hit_bonus,
        .crit_bonus = effects.conflagrate_crit_bonus,
        .crit_multiplier = effects.destruction_crit_multiplier,
    });
    const talent_flags = flags(state, side, i);
    const aftermath: V = @floatFromInt((talent_flags >> @as(@Vector(16, u5), @splat(5))) & @as(U, @splat(7)));
    const ranks: U = @field(state, "talent_ranks" ++ (if (side) "_a" else "_b"))[i..][0..16].*;
    const shadow_flame: V = @floatFromInt(ranks >> @as(@Vector(16, u5), @splat(29)));
    const preserve = roll(state, side, i, mask) < shadow_flame * v(0.2);
    immolate.* = @select(f32, simd.vAnd16(mask, simd.vNot16(preserve)), v(0), immolate.*);
    const daze = simd.vAnd16(resolved.landed, roll(state, side, i, mask) < aftermath * v(0.2));
    const daze_timer = col(state, "daze_timer", !side, i);
    daze_timer.* = @select(f32, daze, v(5), daze_timer.*);
    const buff = col(state, "shadow_flame_timer", side, i);
    buff.* = @select(f32, simd.vAnd16(resolved.landed, shadow_flame > v(0)), v(20), buff.*);
    const cd = col(state, "conflagrate_cd", side, i);
    cd.* = @select(f32, mask, v(C.ConflagrateCooldown), cd.*);
    // Queue immediate damage for the next physics boundary, where shields,
    // Soul Link, damage breaks, overkill and simultaneous deaths resolve.
    const pending = col(state, "conflagrate_pending", side, i);
    const sacrificed_succubus = simd.vAnd16(effects.demonic_sacrifice > v(0), effects.demonic_sacrifice_pet == v(@floatFromInt(@intFromEnum(@import("pets.zig").Kind.succubus))));
    const sacrifice = @select(f32, sacrificed_succubus, v(1.15), v(1));
    pending.* += @select(f32, mask, resolved.damage * effects.fire_damage * sacrifice, v(0));
}
pub fn buffEffects(state: anytype, comptime side: bool, i: usize, effects: *talents.Effects) void {
    const buff = col(state, "shadow_flame_timer", side, i);
    const active = buff.* > v(0);
    if (!@reduce(.Or, active)) return;
    const ranks: U = @field(state, "talent_ranks" ++ (if (side) "_a" else "_b"))[i..][0..16].*;
    const bonus = v(1) + v(0.02) * @as(V, @floatFromInt(ranks >> @as(@Vector(16, u5), @splat(29))));
    const mult = @select(f32, active, bonus, v(1));
    inline for (.{ "shadow_damage", "agony_damage", "corruption_damage", "drain_life_damage", "drain_life_healing", "siphon_life_damage", "siphon_life_healing" }) |field|
        @field(effects, field) *= mult;
}
pub fn tickEffects(state: anytype, comptime side: bool, i: usize, dt: f32, effects: *talents.Effects) void {
    buffEffects(state, side, i, effects);
    inline for (.{ "conflagrate_cd", "shadow_flame_timer" }) |field| {
        const timer = col(state, field, side, i);
        if (@reduce(.Or, timer.* > v(0))) timer.* = @max(v(0), timer.* - v(dt));
    }
}
pub fn speed(state: anytype, comptime side: bool, i: usize) V {
    return @select(f32, col(state, "daze_timer", side, i).* > v(0), v(0.5), v(1));
}
pub fn takeDamage(state: anytype, comptime side: bool, i: usize) V {
    const pending = col(state, "conflagrate_pending", side, i);
    const damage = pending.*;
    if (@reduce(.Or, damage != v(0))) pending.* = v(0);
    return damage;
}
pub fn tickDaze(state: anytype, i: usize, dt: f32) void {
    inline for (.{ true, false }) |side| {
        const timer = col(state, "daze_timer", side, i);
        if (@reduce(.Or, timer.* > v(0))) timer.* = @max(v(0), timer.* - v(dt));
    }
}
