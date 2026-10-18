//! Forever caster racials. Input stats remain unbuffed; Blood Fury scales only
//! the spell-power contribution. Periodics use the engine's dynamic stat model.
const simd = @import("simd.zig");
const Race = @import("spec.zig").Race;
const Spec = @import("spec.zig").Spec;
const V = simd.f32x16;
const U = simd.u32x16;
const B = simd.bool16;
fn v(x: f32) V {
    return @splat(x);
}
fn col(state: anytype, comptime name: []const u8, comptime side: bool, i: usize) V {
    return @field(state, name ++ (if (side) "_a" else "_b"))[i..][0..16].*;
}
fn store(state: anytype, comptime name: []const u8, comptime side: bool, i: usize, value: V) void {
    @field(state, name ++ (if (side) "_a" else "_b"))[i..][0..16].* = value;
}
pub fn fillMasks(state: anytype, comptime side: bool, i: usize, masks: anytype) void {
    const race: U = @field(state, if (side) "race_a" else "race_b")[i..][0..16].*;
    const cast: U = @field(state, if (side) "cast_id_a" else "cast_id_b")[i..][0..16].*;
    const active: U = state.is_active[i..][0..16].*;
    var free = simd.vAnd16(active != @as(U, @splat(0)), simd.vAnd16(col(state, "hp", side, i) > v(0), col(state, "hp", !side, i) > v(0)));
    free = simd.vAnd16(free, col(state, "racial_cd", side, i) <= v(0));
    // A stun or Horror blocks WotF; Charm/Fear/Sleep may be cleansed.
    free = simd.vAnd16(free, simd.vAnd16(col(state, "stun_timer", side, i) <= v(0), col(state, "horror_timer", side, i) <= v(0)));
    masks[20] = simd.vAnd16(free, simd.vAnd16(col(state, "gcd", side, i) <= v(0), race == @as(U, @splat(@intFromEnum(Race.undead)))));
    inline for (.{ "fear_timer", "horror_timer", "seduction_timer" }) |name| free = simd.vAnd16(free, col(state, name, side, i) <= v(0));
    free = simd.vAnd16(free, cast == @as(U, @splat(0)));
    masks[17] = simd.vAnd16(free, race == @as(U, @splat(@intFromEnum(Race.orc))));
    masks[18] = simd.vAnd16(free, race == @as(U, @splat(@intFromEnum(Race.troll))));
    masks[19] = simd.vAnd16(free, simd.vAnd16(col(state, "gcd", side, i) <= v(0), race == @as(U, @splat(@intFromEnum(Race.gnome)))));
}
pub fn apply(state: anytype, comptime side: bool, i: usize, actions: U, comptime opponent: Spec) void {
    var masks: [@import("action_catalog_generated.zig").ActionCount]B = undefined;
    fillMasks(state, side, i, &masks);
    inline for (17..20) |id| {
        const used = simd.vAnd16(masks[id], actions == @as(U, @splat(id)));
        const timer = switch (id) {
            17 => "racial_power_timer",
            18 => "racial_haste_timer",
            19 => "racial_escape_timer",
            else => unreachable,
        };
        const duration: f32 = switch (id) {
            17 => 15,
            18 => 10,
            19 => 3,
            else => unreachable,
        };
        const cooldown: f32 = if (id == 19) 120 else 180;
        store(state, timer, side, i, @select(f32, used, v(duration), col(state, timer, side, i)));
        store(state, "racial_cd", side, i, @select(f32, used, v(cooldown), col(state, "racial_cd", side, i)));
        if (id == 19) {
            store(state, "gcd", side, i, @select(f32, used, v(1.5), col(state, "gcd", side, i)));
            clearMovement(state, side, i, used, opponent);
        }
    }
    const cleansed = simd.vAnd16(masks[20], actions == @as(U, @splat(20)));
    store(state, "racial_cd", side, i, @select(f32, cleansed, v(120), col(state, "racial_cd", side, i)));
    store(state, "gcd", side, i, @select(f32, cleansed, v(1.5), col(state, "gcd", side, i)));
    clearFear(state, side, i, cleansed, opponent);
    store(state, "seduction_timer", side, i, @select(f32, cleansed, v(0), col(state, "seduction_timer", side, i)));
    const seduced: *align(64) U = @ptrCast(@alignCast(@field(state, if (side) "seduced_a" else "seduced_b")[i..][0..16]));
    seduced.* = @select(u32, cleansed, @as(U, @splat(0)), seduced.*);
}

fn clearFear(state: anytype, comptime side: bool, i: usize, used: B, comptime opponent: Spec) void {
    // Polymorph is a transformation, even though Mage reuses the fear slot.
    if (opponent != .frost_mage) inline for (.{ "fear_timer", "fear_accum_dmg" }) |name| {
        store(state, name, side, i, @select(f32, used, v(0), col(state, name, side, i)));
    };
}
pub fn clearMovement(state: anytype, comptime side: bool, i: usize, used: B, comptime opponent: Spec) void {
    // Mage roots/slows reuse DOT slots; never cleanse Warlock curses or DOTs.
    if (opponent == .frost_mage) inline for (.{ "agony_timer", "corruption_timer" }) |name| {
        store(state, name, side, i, @select(f32, used, v(0), col(state, name, side, i)));
    };
}
pub fn powerMultiplier(state: anytype, comptime side: bool, i: usize) V {
    return @select(f32, col(state, "racial_power_timer", side, i) > v(0), v(1.1), v(1));
}
pub fn castStep(state: anytype, comptime side: bool, i: usize, dt: f32) V {
    // Only the portion of this frame before expiry receives haste.
    return v(dt) + @min(v(dt), col(state, "racial_haste_timer", side, i)) * v(0.1);
}
pub fn canImpair(state: anytype, comptime side: bool, i: usize) B {
    return col(state, "racial_escape_timer", side, i) <= v(0);
}
pub fn tick(state: anytype, i: usize, dt: f32) void {
    inline for (.{ true, false }) |side| inline for (.{ "racial_cd", "racial_power_timer", "racial_haste_timer", "racial_escape_timer" }) |name| {
        store(state, name, side, i, @import("periodic.zig").remaining(col(state, name, side, i), dt));
    };
}

pub fn hasteMultiplier(state: anytype, comptime side: bool, i: usize) V {
    return @select(f32, col(state, "racial_haste_timer", side, i) > v(0), v(1.1), v(1));
}
