//! Classic-style direct-damage pushback. DoT/channel ticks never enter this API.
//! Rules reference: vmangos/core Spell::Delayed/DelayedChannel and
//! GetNextDelayAtDamageMsTime (Spell.cpp / Spell.h). Forever overrides unverified.
const simd = @import("simd.zig");
const resolution = @import("spell_resolution.zig");
const talents = @import("warlock_talents.zig");
const projectiles = @import("projectiles.zig");
const V = simd.f32x16;
const U = simd.u32x16;
const B = simd.bool16;
fn v(x: f32) V {
    return @splat(x);
}
fn u(x: u32) U {
    return @splat(x);
}

pub const Result = struct { remaining: V, count: U };
// Supplied rolls keep the scalar/reference oracle independent of RNG details.
pub fn resolveRolls(remaining: V, total: V, count: U, channel: B, resistance: V, roll: V, eligible: B) Result {
    const applied = simd.vAnd16(eligible, roll >= @min(v(1), @max(v(0), resistance)));
    const delay = @max(v(0.2), v(1) - @as(V, @floatFromInt(@min(count, u(4)))) * v(0.2));
    const next = @select(f32, channel, @max(v(0), remaining - delay), @min(total, remaining + delay));
    return .{
        .remaining = @select(f32, applied, next, remaining),
        .count = @select(u32, applied, @min(u(4), count + u(1)), count),
    };
}
pub fn reset(state: anytype, comptime side: bool, i: usize, mask: B) void {
    if (!@reduce(.Or, mask)) return;
    const suffix = if (side) "_a" else "_b";
    const count = @field(state, "cast_pushback_count" ++ suffix);
    const elapsed = @field(state, "channel_elapsed" ++ suffix);
    if (@reduce(.Or, simd.vAnd16(mask, count[i..][0..16].* != u(0)))) count[i..][0..16].* = @select(u32, mask, u(0), count[i..][0..16].*);
    if (@reduce(.Or, simd.vAnd16(mask, elapsed[i..][0..16].* != v(0)))) elapsed[i..][0..16].* = @select(f32, mask, v(0), elapsed[i..][0..16].*);
}
pub fn resistanceFor(comptime warlock: bool, cast: U, effects: talents.Effects) V {
    if (!warlock) return v(0);
    const destruction = simd.vOr16(cast == u(4), simd.vAnd16(cast >= u(11), cast <= u(13)));
    return @select(f32, cast == u(5), effects.fel_concentration_resist, @select(f32, destruction, effects.intensity_resist, v(0)));
}
fn hit(state: anytype, comptime side: bool, i: usize, amount: V, shield: *V, cast: U, remaining: anytype, total: V, channel: B, resistance: V) void {
    if (!@reduce(.Or, amount > v(0))) return;
    const unabsorbed = @max(v(0), amount - shield.*);
    shield.* = @max(v(0), shield.* - amount);
    const suffix = if (side) "_a" else "_b";
    const live = simd.vAnd16(state.is_active[i..][0..16].* != u(0), @field(state, "hp" ++ suffix)[i..][0..16].* > v(0));
    const eligible = simd.vAnd16(live, simd.vAnd16(unabsorbed > v(0), simd.vAnd16(cast != u(0), simd.vAnd16(remaining.* > v(0), total > v(0)))));
    if (!@reduce(.Or, eligible)) return;
    const rolls = resolution.pushbackRoll(state, side, i, simd.vAnd16(eligible, resistance > v(0)));
    const count = @field(state, "cast_pushback_count" ++ suffix);
    const result = resolveRolls(remaining.*, total, count[i..][0..16].*, channel, resistance, rolls, eligible);
    remaining.* = result.remaining;
    count[i..][0..16].* = result.count;
}
/// Warrior direct hits follow the existing projectile/pet hits in the physics
/// step. The caller supplies remaining virtual absorption and Physical damage
/// after mitigation, preserving the original caster-only path.
pub fn melee(state: anytype, comptime side: bool, i: usize, damage: V, absorb: V, cast: U, remaining: anytype, total: V, channel: B, resistance: V) void {
    var shield = absorb;
    hit(state, side, i, damage, &shield, cast, remaining, total, channel, resistance);
}
// Individual projectile slots, Conflagrate, then the autonomous pet are resolved
// in that order. Direct hits consume the virtual shield before periodic damage;
// aggregate HP/shield accounting remains in the combat kernel. Misses, resists,
// and fully absorbed hits have zero qualifying damage and cannot push back.
pub fn apply(state: anytype, comptime side: bool, comptime warlock: bool, i: usize, hits: projectiles.Hits, pet_damage: V, mitigation: V, absorb: V, effects: talents.Effects, cast: U, remaining: anytype, total: V) void {
    if (!@reduce(.Or, cast != u(0))) return;
    var shield = absorb;
    const channel = if (warlock) cast == u(5) else @as(B, @splat(false));
    const resistance = resistanceFor(warlock, cast, effects);
    inline for (0..projectiles.Slots) |slot| hit(state, side, i, hits.direct_events[slot] * mitigation, &shield, cast, remaining, total, channel, resistance);
    hit(state, side, i, hits.conflagrate * mitigation, &shield, cast, remaining, total, channel, resistance);
    hit(state, side, i, pet_damage * (if (warlock) @import("demon_passives.zig").petMitigation(state, side, i, mitigation) else mitigation), &shield, cast, remaining, total, channel, resistance);
}

pub fn applyPriest(state: anytype, comptime side: bool, i: usize, hits: projectiles.Hits, pet_damage: V, mitigation: V, absorb: V, pushback_resist: V, cast: U, remaining: anytype, total: V) void {
    if (!@reduce(.Or, cast != u(0))) return;
    var shield = absorb;
    const channel = simd.vOr16(cast == u(5), cast == u(15));
    inline for (0..projectiles.Slots) |slot| hit(state, side, i, hits.direct_events[slot] * mitigation, &shield, cast, remaining, total, channel, pushback_resist);
    hit(state, side, i, hits.conflagrate * mitigation, &shield, cast, remaining, total, channel, pushback_resist);
    hit(state, side, i, pet_damage * mitigation, &shield, cast, remaining, total, channel, pushback_resist);
}
